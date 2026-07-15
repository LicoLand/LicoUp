use anyhow::{Result, anyhow};
use regex::Regex;
use rusqlite::{Connection, TransactionBehavior};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const CONVERSATION_SCHEMA_VERSION: u32 = 2;
const MAX_HISTORY_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_HISTORY_FILES: usize = 8_000;
const MAX_HISTORY_DIRECTORY_ENTRIES: usize = 16_000;
const MAX_HISTORY_DIRECTORY_DEPTH: usize = 32;
const MAX_HISTORY_PAGE_LIMIT: usize = 500;
const MAX_SQLITE_ROWS_PER_TABLE: usize = 2_000;
const ARCHIVE_SQLITE_PAGE_ROWS: usize = 2_000;
const ARCHIVE_DISCOVERY_PREVIEW_MESSAGES: usize = 12;
const ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS: usize = 8_000;
const MAX_STRUCTURED_EVENT_TEXT_CHARS: usize = 1_200;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HistoryMessageKind {
    Text,
    ToolCall,
    ToolResult,
    Reasoning,
    Metadata,
    Error,
    Event,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HistoryAdapter {
    Antigravity,
    ClaudeCode,
    Code,
    Codex,
    Copilot,
    Cursor,
    Hermes,
    KiloCode,
    Kimi,
    KimiCode,
    OpenClaw,
    OpenCode,
    Pi,
}

struct HistoryRoot {
    path: PathBuf,
    source_kind: String,
}

#[derive(Clone, Debug)]
struct HistoryFileCandidate {
    path: PathBuf,
    source_kind: String,
    modified_at: SystemTime,
}

#[derive(Clone, Debug)]
struct HistoryScanConfig {
    archive_mode: bool,
    session_ids: Vec<String>,
    match_terms: Vec<String>,
    match_project_paths: Vec<String>,
    page: HistoryPageConfig,
}

#[derive(Clone, Debug)]
struct HistoryPageConfig {
    offset: usize,
    limit: Option<usize>,
}

impl HistoryScanConfig {
    fn from_params(params: &Value) -> Self {
        Self {
            archive_mode: param_bool(params, "archiveMode").unwrap_or(false),
            session_ids: string_list_param(params, &["sessionIds", "sessionId"]),
            match_terms: string_list_param(params, &["matchTerms", "matchTerm"]),
            match_project_paths: string_list_param(
                params,
                &["matchProjectPaths", "matchProjectPath"],
            ),
            page: HistoryPageConfig::from_params(params),
        }
    }

    fn matches_session(&self, session: &Value) -> bool {
        if !self.session_ids.is_empty() {
            let projected_id = session
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let native_id = session
                .get("nativeSessionId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !self
                .session_ids
                .iter()
                .any(|session_id| session_id == projected_id || session_id == native_id)
            {
                return false;
            }
        }
        if self.match_terms.is_empty() && self.match_project_paths.is_empty() {
            return true;
        }
        let text = history_match_text(session);
        let normalized = normalize_history_match_text(&text);
        let text_matches = self.match_terms.iter().any(|term| {
            let normalized_term = normalize_history_match_text(term);
            !normalized_term.is_empty()
                && normalized_contains_history_term(&normalized, &normalized_term)
        });
        if text_matches {
            return true;
        }
        if self.match_project_paths.is_empty() {
            return false;
        }
        let path_text = history_match_path_text(session);
        let normalized_path = normalize_history_match_text(&path_text);
        self.match_project_paths.iter().any(|term| {
            let normalized_term = normalize_history_match_text(term);
            path_text.contains(term)
                || (!normalized_term.is_empty()
                    && normalized_contains_history_term(&normalized_path, &normalized_term))
        })
    }

    fn has_match_filters(&self) -> bool {
        !self.match_terms.is_empty() || !self.match_project_paths.is_empty()
    }

    fn has_single_session_filter(&self) -> bool {
        self.session_ids.len() == 1
    }

    fn matched_terms(&self, session: &Value) -> Vec<String> {
        let text = history_match_text(session);
        let path_text = history_match_path_text(session);
        self.matched_terms_in_text_and_path(&text, &path_text)
    }

    fn matched_terms_in_text_and_path(&self, text: &str, path_text: &str) -> Vec<String> {
        let normalized = normalize_history_match_text(text);
        let normalized_path = normalize_history_match_text(path_text);
        let mut matched = Vec::<String>::new();
        for term in self
            .match_terms
            .iter()
            .chain(self.match_project_paths.iter())
        {
            let normalized_term = normalize_history_match_text(term);
            if normalized_term.is_empty() {
                continue;
            }
            let text_match = normalized_contains_history_term(&normalized, &normalized_term);
            let path_match = path_text.contains(term)
                || normalized_contains_history_term(&normalized_path, &normalized_term);
            if text_match || path_match {
                matched.push(term.clone());
            }
        }
        matched.sort();
        matched.dedup();
        matched
    }

    fn compact_session_for_archive_discovery(&self, mut session: Value) -> Value {
        if !self.has_match_filters() || source_path_is_sqlite(&session) {
            return session;
        }
        let matched_terms = self.matched_terms(&session);
        let has_conversation = history_session_has_real_conversation(&session);
        if let Some(object) = session.as_object_mut() {
            object.insert(
                "archiveDiscoveryHasConversation".to_string(),
                json!(has_conversation),
            );
            object.insert(
                "archiveDiscoveryMatchedTerms".to_string(),
                json!(matched_terms),
            );
            if let Some(messages) = object.get("messages").and_then(Value::as_array) {
                let preview = messages
                    .iter()
                    .filter(|message| history_message_is_matchable(message))
                    .take(12)
                    .cloned()
                    .collect::<Vec<_>>();
                object.insert("messages".to_string(), Value::Array(preview));
                object.insert(
                    "messagesTruncatedForArchiveDiscovery".to_string(),
                    json!(true),
                );
            }
        }
        session
    }
}

impl HistoryPageConfig {
    fn from_params(params: &Value) -> Self {
        Self {
            offset: number_param(params, "offset").unwrap_or(0) as usize,
            limit: number_param(params, "limit")
                .map(|value| (value as usize).clamp(1, MAX_HISTORY_PAGE_LIMIT)),
        }
    }

    fn end(&self) -> Option<usize> {
        self.limit.map(|limit| self.offset.saturating_add(limit))
    }

    fn has_more(&self, total: usize) -> bool {
        self.end().map(|end| total > end).unwrap_or(false)
    }
}

impl HistoryAdapter {
    fn id(self) -> &'static str {
        match self {
            HistoryAdapter::Antigravity => "antigravity",
            HistoryAdapter::ClaudeCode => "claude-code",
            HistoryAdapter::Code => "code",
            HistoryAdapter::Codex => "codex",
            HistoryAdapter::Copilot => "copilot",
            HistoryAdapter::Cursor => "cursor",
            HistoryAdapter::Hermes => "hermes",
            HistoryAdapter::KiloCode => "kilo-code",
            HistoryAdapter::Kimi => "kimi",
            HistoryAdapter::KimiCode => "kimi-code",
            HistoryAdapter::OpenClaw => "openclaw",
            HistoryAdapter::OpenCode => "opencode",
            HistoryAdapter::Pi => "pi",
        }
    }

    fn label(self) -> &'static str {
        match self {
            HistoryAdapter::Antigravity => "Antigravity - IDE",
            HistoryAdapter::ClaudeCode => "Claude Code - CLI",
            HistoryAdapter::Code => "Visual Studio Code - IDE",
            HistoryAdapter::Codex => "ChatGPT - Desktop",
            HistoryAdapter::Copilot => "GitHub Copilot - Plugin",
            HistoryAdapter::Cursor => "Cursor - IDE",
            HistoryAdapter::Hermes => "Hermes Agent - CLI",
            HistoryAdapter::KiloCode => "Kilo Code - CLI",
            HistoryAdapter::Kimi => "Kimi - Desktop",
            HistoryAdapter::KimiCode => "Kimi Code - CLI",
            HistoryAdapter::OpenClaw => "OpenClaw - CLI",
            HistoryAdapter::OpenCode => "OpenCode - CLI",
            HistoryAdapter::Pi => "Pi Agent - CLI",
        }
    }

    fn accepts_file(self, path: &Path, extension: &str) -> bool {
        if self == HistoryAdapter::KimiCode {
            return extension == "jsonl"
                && path.file_name().and_then(|value| value.to_str()) == Some("wire.jsonl")
                && path
                    .components()
                    .any(|component| component.as_os_str() == "agents");
        }
        if path
            .file_name()
            .and_then(|value| value.to_str())
            .map(|name| name.ends_with(".backup") || name == "codebase-external.sqlite")
            .unwrap_or(false)
        {
            return false;
        }
        match self {
            HistoryAdapter::Codex => matches!(extension, "jsonl" | "ndjson" | "json" | "md"),
            HistoryAdapter::ClaudeCode => matches!(extension, "jsonl" | "json" | "md" | "txt"),
            HistoryAdapter::Code => matches!(
                extension,
                "jsonl"
                    | "ndjson"
                    | "json"
                    | "md"
                    | "txt"
                    | "log"
                    | "sqlite"
                    | "sqlite3"
                    | "db"
                    | "vscdb"
            ),
            HistoryAdapter::Antigravity => {
                matches!(
                    extension,
                    "jsonl"
                        | "ndjson"
                        | "json"
                        | "md"
                        | "txt"
                        | "log"
                        | "sqlite"
                        | "sqlite3"
                        | "db"
                        | "vscdb"
                )
            }
            HistoryAdapter::Cursor | HistoryAdapter::Copilot => {
                matches!(
                    extension,
                    "jsonl" | "ndjson" | "json" | "sqlite" | "sqlite3" | "db" | "vscdb"
                )
            }
            HistoryAdapter::KiloCode => {
                matches!(
                    extension,
                    "jsonl"
                        | "ndjson"
                        | "json"
                        | "md"
                        | "txt"
                        | "log"
                        | "sqlite"
                        | "sqlite3"
                        | "db"
                )
            }
            HistoryAdapter::OpenCode
            | HistoryAdapter::OpenClaw
            | HistoryAdapter::Hermes
            | HistoryAdapter::Kimi
            | HistoryAdapter::KimiCode
            | HistoryAdapter::Pi => {
                matches!(
                    extension,
                    "jsonl"
                        | "ndjson"
                        | "json"
                        | "md"
                        | "txt"
                        | "log"
                        | "sqlite"
                        | "sqlite3"
                        | "db"
                )
            }
        }
    }

    fn sqlite_table_may_hold_history(self, name: &str) -> bool {
        let lower = name.to_ascii_lowercase();
        if lower.starts_with("sqlite") || lower.contains("fts") || lower.contains("embedding") {
            return false;
        }
        if self == HistoryAdapter::KiloCode
            && (lower.contains("account") || lower.contains("control_account"))
        {
            return false;
        }
        match self {
            HistoryAdapter::Code => {
                lower == "itemtable"
                    || lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
                    || lower.contains("workspace")
                    || lower.contains("state")
            }
            HistoryAdapter::Cursor | HistoryAdapter::Copilot | HistoryAdapter::Antigravity => {
                lower == "itemtable"
                    || lower == "cursordiskkv"
                    || lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
            }
            _ => {
                lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
                    || lower == "itemtable"
            }
        }
    }

    fn sqlite_row_may_hold_history(self, table: &str, key: Option<&str>, row_text: &str) -> bool {
        let key = key.unwrap_or_default().to_ascii_lowercase();
        let text = row_text.to_ascii_lowercase();
        match self {
            HistoryAdapter::Code => {
                key.contains("chat")
                    || key.contains("conversation")
                    || key.contains("session")
                    || key.contains("history")
                    || key.contains("workspace")
                    || key.contains("recent")
                    || looks_like_history_text(row_text)
            }
            HistoryAdapter::Copilot => {
                key.contains("github.copilot")
                    || key.contains("copilot")
                    || key.contains("chatsessions")
                    || text.contains("copilot")
            }
            HistoryAdapter::Cursor => {
                key.contains("aichat")
                    || key.contains("composer")
                    || key.contains("chat")
                    || key.contains("conversation")
                    || key.starts_with("bubbleid:")
                    || key.starts_with("composerdata:")
                    || looks_like_history_text(row_text)
            }
            HistoryAdapter::KiloCode => {
                !table.to_ascii_lowercase().contains("account") && looks_like_history_text(row_text)
            }
            _ => looks_like_history_text(row_text),
        }
    }
}

fn adapter_for_agent(agent_id: &str) -> Option<HistoryAdapter> {
    match agent_id {
        "antigravity" => Some(HistoryAdapter::Antigravity),
        "claude" | "claude-code" => Some(HistoryAdapter::ClaudeCode),
        "code" | "vscode" | "vs-code" => Some(HistoryAdapter::Code),
        "codex" => Some(HistoryAdapter::Codex),
        "copilot" | "github-copilot" => Some(HistoryAdapter::Copilot),
        "cursor" => Some(HistoryAdapter::Cursor),
        "hermes" | "hermes-agent" => Some(HistoryAdapter::Hermes),
        "kilo" | "kilo-code" => Some(HistoryAdapter::KiloCode),
        "kimi" | "moonshot" => Some(HistoryAdapter::Kimi),
        "kimi-code" | "kimi_code" | "kimicode" => Some(HistoryAdapter::KimiCode),
        "openclaw" => Some(HistoryAdapter::OpenClaw),
        "opencode" => Some(HistoryAdapter::OpenCode),
        "pi" | "pi-agent" | "pi-coding-agent" => Some(HistoryAdapter::Pi),
        _ => None,
    }
}

pub fn conversation_list(params: &Value) -> Result<Value> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    let roots = history_roots(adapter, params);
    let mut sessions = Vec::<Value>::new();
    let mut skipped = Vec::<Value>::new();
    let mut files_seen = 0usize;
    let mut directory_entries_seen = 0usize;

    for root in roots {
        scan_history_path(
            adapter,
            &root.path,
            &root.source_kind,
            scan_config.clone(),
            &mut sessions,
            &mut skipped,
            &mut files_seen,
            &mut directory_entries_seen,
            0,
        );
    }
    if adapter == HistoryAdapter::Codex && !scan_config.has_single_session_filter() {
        apply_codex_session_index_titles(params, &mut sessions);
    }
    let mut sessions = dedupe_history_sessions(finalize_history_sessions(sessions, &scan_config));
    sort_sessions_by_updated_at(&mut sessions);
    let total_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);
    let sessions = paged_history_sessions(sessions, &scan_config.page);
    let returned_sessions = sessions.len();

    Ok(json!({
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "mode": "native-history",
        "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": agent_id,
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sessions": sessions,
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit,
            "returned": returned_sessions,
            "totalSessions": total_sessions,
            "hasMore": has_more
        },
        "sources": {
            "filesSeen": files_seen,
            "directoryEntriesSeen": directory_entries_seen,
            "skipped": skipped
        }
    }))
}

pub fn model_catalog(params: &Value) -> Result<Value> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    let roots = history_roots(adapter, params);
    let mut candidates = Vec::<HistoryFileCandidate>::new();
    let mut skipped = Vec::<Value>::new();
    let mut files_seen = 0usize;

    for root in roots {
        collect_history_file_candidates(
            adapter,
            &root.path,
            &root.source_kind,
            &scan_config,
            &mut candidates,
            &mut skipped,
            &mut files_seen,
        );
    }
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.path.cmp(&right.path))
    });
    let file_limit = number_param(params, "historyModelCatalogFileLimit")
        .unwrap_or(80)
        .clamp(1, 500) as usize;
    let mut names = BTreeSet::<String>::new();
    for candidate in candidates.into_iter().take(file_limit) {
        let Ok(metadata) = fs::metadata(&candidate.path) else {
            continue;
        };
        let sessions = parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        );
        for session in sessions {
            collect_history_model_names(&session, &mut names, 0);
        }
    }
    let models = names
        .into_iter()
        .map(|name| {
            json!({
                "name": name,
                "source": "history",
                "sources": ["history"],
                "reasoningEfforts": []
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "ok": true,
        "status": if models.is_empty() { "empty" } else { "available" },
        "source": "history",
        "models": models,
        "sources": {
            "filesSeen": files_seen,
            "skippedCount": skipped.len()
        }
    }))
}

pub fn conversation_stream(params: &Value) -> Result<()> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    // Codex fork/continuation lineage spans multiple rollout files. Buffer and
    // finalize globally before paging so stream matches conversation_list.
    if adapter == HistoryAdapter::Codex {
        return conversation_stream_codex_finalized(params, &agent_id, adapter, &scan_config);
    }
    let roots = history_roots(adapter, params);
    let mut candidates = Vec::<HistoryFileCandidate>::new();
    let mut skipped = Vec::<Value>::new();
    let mut files_seen = 0usize;

    for root in roots {
        collect_history_file_candidates(
            adapter,
            &root.path,
            &root.source_kind,
            &scan_config,
            &mut candidates,
            &mut skipped,
            &mut files_seen,
        );
    }
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.path.cmp(&right.path))
    });

    emit_json_line(&json!({
        "event": "start",
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "mode": "native-history",
        "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": agent_id,
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sources": {
            "filesSeen": files_seen,
            "candidateFiles": candidates.len(),
            "skippedCount": skipped.len()
        },
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit
        }
    }))?;

    let mut emitted_session_keys = BTreeSet::<String>::new();
    let mut matched_sessions = 0usize;
    let mut returned_sessions = 0usize;
    let mut has_more = false;
    'candidate_loop: for candidate in candidates {
        let metadata = match fs::metadata(&candidate.path) {
            Ok(metadata) => metadata,
            Err(error) => {
                emit_json_line(&json!({
                    "event": "skip",
                    "ok": true,
                    "reason": "metadata_failed",
                    "error": error.to_string()
                }))?;
                continue;
            }
        };
        let sessions = parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        );
        let mut sessions = finalize_history_sessions(sessions, &scan_config);
        sort_sessions_by_updated_at(&mut sessions);
        for session in sessions {
            let key = history_session_dedupe_key(&session);
            if !emitted_session_keys.insert(key) {
                continue;
            }
            let current_index = matched_sessions;
            matched_sessions = matched_sessions.saturating_add(1);
            if current_index < scan_config.page.offset {
                continue;
            }
            if let Some(end) = scan_config.page.end() {
                if current_index >= end {
                    has_more = true;
                    break 'candidate_loop;
                }
            }
            emit_json_line(&json!({
                "event": "session",
                "ok": true,
                "agentId": agent_id,
                "session": session
            }))?;
            returned_sessions = returned_sessions.saturating_add(1);
            if scan_config.has_single_session_filter() {
                break 'candidate_loop;
            }
        }
    }

    emit_json_line(&json!({
        "event": "done",
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "agentId": agent_id,
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit,
            "returned": returned_sessions,
            "scannedSessions": matched_sessions,
            "hasMore": has_more
        }
    }))?;
    Ok(())
}

fn conversation_stream_codex_finalized(
    params: &Value,
    agent_id: &str,
    adapter: HistoryAdapter,
    scan_config: &HistoryScanConfig,
) -> Result<()> {
    let roots = history_roots(adapter, params);
    let mut sessions = Vec::<Value>::new();
    let mut skipped = Vec::<Value>::new();
    let mut files_seen = 0usize;
    let mut directory_entries_seen = 0usize;
    for root in roots {
        scan_history_path(
            adapter,
            &root.path,
            &root.source_kind,
            scan_config.clone(),
            &mut sessions,
            &mut skipped,
            &mut files_seen,
            &mut directory_entries_seen,
            0,
        );
    }
    if !scan_config.has_single_session_filter() {
        apply_codex_session_index_titles(params, &mut sessions);
    }
    let mut sessions = dedupe_history_sessions(finalize_history_sessions(sessions, scan_config));
    sort_sessions_by_updated_at(&mut sessions);
    let total_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);
    let page = paged_history_sessions(sessions, &scan_config.page);
    let returned_sessions = page.len();

    emit_json_line(&json!({
        "event": "start",
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "mode": "native-history",
        "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": agent_id,
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sources": {
            "filesSeen": files_seen,
            "directoryEntriesSeen": directory_entries_seen,
            "candidateFiles": files_seen,
            "skippedCount": skipped.len()
        },
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit
        }
    }))?;
    for session in page {
        emit_json_line(&json!({
            "event": "session",
            "ok": true,
            "agentId": agent_id,
            "session": session
        }))?;
    }
    emit_json_line(&json!({
        "event": "done",
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "agentId": agent_id,
        "page": {
            "offset": scan_config.page.offset,
            "limit": scan_config.page.limit,
            "returned": returned_sessions,
            "scannedSessions": total_sessions,
            "hasMore": has_more
        }
    }))?;
    Ok(())
}

pub fn conversation_append(_params: &Value) -> Result<Value> {
    Err(anyhow!(
        "native agent history is read-only; LicoLite does not create synthetic local conversations"
    ))
}

pub fn conversation_delete(_params: &Value) -> Result<Value> {
    Err(anyhow!(
        "native agent history is read-only; LicoLite does not delete source agent conversations"
    ))
}

fn scan_history_path(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    scan_config: HistoryScanConfig,
    sessions: &mut Vec<Value>,
    skipped: &mut Vec<Value>,
    files_seen: &mut usize,
    directory_entries_seen: &mut usize,
    depth: usize,
) {
    if !scan_config.archive_mode && *files_seen >= MAX_HISTORY_FILES {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "file_limit_reached"
        }));
        return;
    }
    if let Some(reason) = excluded_history_path_reason(path) {
        skipped.push(json!({
            "path": display_path(path),
            "reason": reason
        }));
        return;
    }
    if !path.exists() {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "not_present"
        }));
        return;
    }
    if path.is_dir() {
        if depth >= MAX_HISTORY_DIRECTORY_DEPTH {
            skipped.push(json!({
                "path": display_path(path),
                "reason": "directory_depth_limit_reached"
            }));
            return;
        }
        let entries = match fs::read_dir(path) {
            Ok(entries) => entries,
            Err(error) => {
                skipped.push(json!({
                    "path": display_path(path),
                    "reason": "read_dir_failed",
                    "error": error.to_string()
                }));
                return;
            }
        };
        for entry in entries.flatten() {
            if *directory_entries_seen >= MAX_HISTORY_DIRECTORY_ENTRIES {
                skipped.push(json!({
                    "path": display_path(path),
                    "reason": "directory_entry_limit_reached"
                }));
                break;
            }
            *directory_entries_seen = directory_entries_seen.saturating_add(1);
            scan_history_path(
                adapter,
                &entry.path(),
                source_kind,
                scan_config.clone(),
                sessions,
                skipped,
                files_seen,
                directory_entries_seen,
                depth.saturating_add(1),
            );
            if !scan_config.archive_mode && *files_seen >= MAX_HISTORY_FILES {
                break;
            }
        }
        return;
    }

    if !codex_exact_session_file_candidate(adapter, path, source_kind, &scan_config) {
        return;
    }

    *files_seen += 1;
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => {
            skipped.push(json!({
                "path": display_path(path),
                "reason": "metadata_failed",
                "error": error.to_string()
            }));
            return;
        }
    };
    if !scan_config.archive_mode
        && metadata.len() > MAX_HISTORY_FILE_BYTES
        && !history_file_can_exceed_byte_limit(adapter, path)
    {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "file_too_large",
            "bytes": metadata.len()
        }));
        return;
    }

    let parsed = parse_history_file(adapter, path, source_kind, &metadata, scan_config);
    sessions.extend(parsed);
}

fn codex_exact_session_file_candidate(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    scan_config: &HistoryScanConfig,
) -> bool {
    if adapter != HistoryAdapter::Codex || !scan_config.has_single_session_filter() {
        return true;
    }
    let session_id = scan_config.session_ids[0].as_str();
    match source_kind {
        "codex-session-store" | "codex-archived-session-store" => path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains(session_id)),
        "codex-prompt-history"
        | "codex-session-index"
        | "codex-memory"
        | "codex-rollout-summary" => false,
        _ => true,
    }
}

fn collect_history_file_candidates(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    scan_config: &HistoryScanConfig,
    candidates: &mut Vec<HistoryFileCandidate>,
    skipped: &mut Vec<Value>,
    files_seen: &mut usize,
) {
    if !scan_config.archive_mode && *files_seen >= MAX_HISTORY_FILES {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "file_limit_reached"
        }));
        return;
    }
    if let Some(reason) = excluded_history_path_reason(path) {
        skipped.push(json!({
            "path": display_path(path),
            "reason": reason
        }));
        return;
    }
    if !path.exists() {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "not_present"
        }));
        return;
    }
    if path.is_dir() {
        let entries = match fs::read_dir(path) {
            Ok(entries) => entries,
            Err(error) => {
                skipped.push(json!({
                    "path": display_path(path),
                    "reason": "read_dir_failed",
                    "error": error.to_string()
                }));
                return;
            }
        };
        for entry in entries.flatten() {
            collect_history_file_candidates(
                adapter,
                &entry.path(),
                source_kind,
                scan_config,
                candidates,
                skipped,
                files_seen,
            );
            if !scan_config.archive_mode && *files_seen >= MAX_HISTORY_FILES {
                break;
            }
        }
        return;
    }

    *files_seen += 1;
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => {
            skipped.push(json!({
                "path": display_path(path),
                "reason": "metadata_failed",
                "error": error.to_string()
            }));
            return;
        }
    };
    if !scan_config.archive_mode
        && metadata.len() > MAX_HISTORY_FILE_BYTES
        && !history_file_can_exceed_byte_limit(adapter, path)
    {
        skipped.push(json!({
            "path": display_path(path),
            "reason": "file_too_large",
            "bytes": metadata.len()
        }));
        return;
    }

    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !adapter.accepts_file(path, &extension) {
        return;
    }

    candidates.push(HistoryFileCandidate {
        path: path.to_path_buf(),
        source_kind: source_kind.to_string(),
        modified_at: metadata.modified().unwrap_or(UNIX_EPOCH),
    });
}

fn parse_history_file(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Vec<Value> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !adapter.accepts_file(path, &extension) {
        return Vec::new();
    }
    if adapter == HistoryAdapter::KimiCode
        && path.file_name().and_then(|value| value.to_str()) == Some("wire.jsonl")
        && path
            .components()
            .any(|component| component.as_os_str() == "agents")
    {
        return parse_kimi_code_wire_session(path, source_kind, metadata);
    }
    let parsed = match extension.as_str() {
        "jsonl" | "ndjson" => {
            parse_jsonl_sessions(adapter, path, source_kind, metadata, scan_config.clone())
        }
        "json" => parse_json_sessions(adapter, path, source_kind, metadata),
        "md" | "markdown" | "txt" | "log" => {
            parse_text_session(adapter, path, source_kind, metadata)
        }
        "sqlite" | "sqlite3" | "db" | "vscdb" => {
            parse_sqlite_sessions(adapter, path, source_kind, metadata, scan_config.clone())
        }
        _ => Vec::new(),
    };
    parsed
}

fn parse_kimi_code_wire_session(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return Vec::new(),
    };
    let mut messages = Vec::<Value>::new();
    let mut fallback_user_messages = Vec::<Value>::new();
    let mut fallback_agent_messages = Vec::<Value>::new();
    let mut saw_user = false;
    let mut saw_agent = false;
    let mut assistant_text = String::new();
    let mut assistant_index = 0usize;
    let mut assistant_created_at = None::<String>;
    let mut assistant_group = None::<String>;
    let mut reasoning_text = String::new();
    let mut reasoning_summaries = Vec::<Value>::new();
    let mut reasoning_index = 0usize;
    let mut reasoning_created_at = None::<String>;
    let mut reasoning_group = None::<String>;
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let Ok(line) = line else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("turn.prompt") => {
                flush_kimi_code_assistant(
                    path,
                    &mut messages,
                    &mut assistant_text,
                    assistant_index,
                    assistant_created_at.take(),
                );
                assistant_group = None;
                flush_kimi_code_reasoning(
                    path,
                    &mut messages,
                    &mut reasoning_text,
                    &mut reasoning_summaries,
                    reasoning_index,
                    reasoning_created_at.take(),
                );
                reasoning_group = None;
                if let Some(text) = value.get("input").and_then(extract_text)
                    && let Some(message) = plain_history_message(
                        HistoryAdapter::KimiCode,
                        path,
                        index,
                        0,
                        "user",
                        &text,
                        extract_timestamp(&value),
                    )
                {
                    messages.push(message);
                    saw_user = true;
                }
            }
            Some("context.append_message") => {
                let mut message_value = value.get("message").cloned().unwrap_or(Value::Null);
                if let Some(object) = message_value.as_object_mut()
                    && !object.contains_key("time")
                    && let Some(time) = value.get("time")
                {
                    object.insert("time".to_string(), time.clone());
                }
                for parsed in
                    messages_from_json(HistoryAdapter::KimiCode, path, index, &message_value)
                {
                    match parsed.get("role").and_then(Value::as_str) {
                        Some("user" | "human") => fallback_user_messages.push(parsed),
                        Some("agent" | "assistant" | "model" | "ai") => {
                            fallback_agent_messages.push(parsed)
                        }
                        _ => {}
                    }
                }
            }
            Some("context.append_loop_event") => {
                let event = value.get("event").unwrap_or(&value);
                let semantic = event
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let created_at = extract_timestamp(&value).or_else(|| extract_timestamp(event));
                match semantic {
                    "content.part" => {
                        let part = event.get("part").unwrap_or(event);
                        let group = kimi_code_content_group(&value, event);
                        match part.get("type").and_then(Value::as_str) {
                            Some("text") => {
                                flush_kimi_code_reasoning(
                                    path,
                                    &mut messages,
                                    &mut reasoning_text,
                                    &mut reasoning_summaries,
                                    reasoning_index,
                                    reasoning_created_at.take(),
                                );
                                reasoning_group = None;
                                if assistant_group
                                    .as_deref()
                                    .is_some_and(|active| active != group)
                                {
                                    flush_kimi_code_assistant(
                                        path,
                                        &mut messages,
                                        &mut assistant_text,
                                        assistant_index,
                                        assistant_created_at.take(),
                                    );
                                }
                                if let Some(text) = part.get("text").and_then(extract_text)
                                    && !text.is_empty()
                                {
                                    if assistant_text.is_empty() {
                                        assistant_index = index;
                                        assistant_created_at = created_at;
                                        assistant_group = Some(group);
                                    }
                                    assistant_text.push_str(&text);
                                    saw_agent = true;
                                }
                            }
                            Some("think") => {
                                flush_kimi_code_assistant(
                                    path,
                                    &mut messages,
                                    &mut assistant_text,
                                    assistant_index,
                                    assistant_created_at.take(),
                                );
                                assistant_group = None;
                                if reasoning_group
                                    .as_deref()
                                    .is_some_and(|active| active != group)
                                {
                                    flush_kimi_code_reasoning(
                                        path,
                                        &mut messages,
                                        &mut reasoning_text,
                                        &mut reasoning_summaries,
                                        reasoning_index,
                                        reasoning_created_at.take(),
                                    );
                                }
                                if reasoning_text.is_empty() {
                                    reasoning_index = index;
                                    reasoning_created_at = created_at;
                                    reasoning_group = Some(group);
                                }
                                if let Some(text) = part
                                    .get("think")
                                    .or_else(|| part.get("text"))
                                    .and_then(extract_text)
                                {
                                    reasoning_text.push_str(&text);
                                }
                                for key in ["summary", "reasoningSummary", "reasoning_summary"] {
                                    if let Some(summary) = part.get(key) {
                                        reasoning_summaries.push(summary.clone());
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    "tool.call" | "tool.result" => {
                        flush_kimi_code_assistant(
                            path,
                            &mut messages,
                            &mut assistant_text,
                            assistant_index,
                            assistant_created_at.take(),
                        );
                        assistant_group = None;
                        flush_kimi_code_reasoning(
                            path,
                            &mut messages,
                            &mut reasoning_text,
                            &mut reasoning_summaries,
                            reasoning_index,
                            reasoning_created_at.take(),
                        );
                        reasoning_group = None;
                        messages.push(structured_history_message(
                            HistoryAdapter::KimiCode,
                            path,
                            index,
                            0,
                            if semantic == "tool.call" {
                                HistoryMessageKind::ToolCall
                            } else {
                                HistoryMessageKind::ToolResult
                            },
                            semantic,
                            event,
                            created_at,
                        ));
                    }
                    _ => {}
                }
            }
            Some("usage.record") => {
                if !saw_user {
                    messages.append(&mut fallback_user_messages);
                }
                if !saw_agent {
                    messages.append(&mut fallback_agent_messages);
                }
                if !saw_user {
                    messages.append(&mut fallback_user_messages);
                }
                if !saw_agent {
                    messages.append(&mut fallback_agent_messages);
                }
                flush_kimi_code_assistant(
                    path,
                    &mut messages,
                    &mut assistant_text,
                    assistant_index,
                    assistant_created_at.take(),
                );
                assistant_group = None;
                flush_kimi_code_reasoning(
                    path,
                    &mut messages,
                    &mut reasoning_text,
                    &mut reasoning_summaries,
                    reasoning_index,
                    reasoning_created_at.take(),
                );
                reasoning_group = None;
                if let Some(message) = kimi_code_usage_message(path, index, &value) {
                    messages.push(message);
                }
            }
            _ => {}
        }
    }
    flush_kimi_code_assistant(
        path,
        &mut messages,
        &mut assistant_text,
        assistant_index,
        assistant_created_at,
    );
    flush_kimi_code_reasoning(
        path,
        &mut messages,
        &mut reasoning_text,
        &mut reasoning_summaries,
        reasoning_index,
        reasoning_created_at,
    );
    if !saw_user {
        messages.extend(fallback_user_messages);
    }
    if !saw_agent {
        messages.extend(fallback_agent_messages);
    }
    if messages.is_empty() {
        return Vec::new();
    }
    let explicit_title = path
        .ancestors()
        .nth(3)
        .map(|session_root| session_root.join("state.json"))
        .and_then(|state_path| fs::read_to_string(state_path).ok())
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|state| extract_conversation_title(&state));
    vec![session_from_messages_with_title(
        HistoryAdapter::KimiCode,
        path,
        metadata,
        source_kind,
        kimi_code_native_session_id(path),
        messages,
        explicit_title,
    )]
}

fn flush_kimi_code_assistant(
    path: &Path,
    messages: &mut Vec<Value>,
    text: &mut String,
    index: usize,
    created_at: Option<String>,
) {
    if text.is_empty() {
        return;
    }
    if let Some(message) = plain_history_message(
        HistoryAdapter::KimiCode,
        path,
        index,
        0,
        "agent",
        text,
        created_at,
    ) {
        messages.push(message);
    }
    text.clear();
}

fn flush_kimi_code_reasoning(
    path: &Path,
    messages: &mut Vec<Value>,
    text: &mut String,
    summaries: &mut Vec<Value>,
    index: usize,
    created_at: Option<String>,
) {
    if text.is_empty() && summaries.is_empty() {
        return;
    }
    let mut value = json!({"text": std::mem::take(text)});
    if !summaries.is_empty() {
        value["summary"] = Value::Array(std::mem::take(summaries));
    }
    messages.push(structured_history_message(
        HistoryAdapter::KimiCode,
        path,
        index,
        0,
        HistoryMessageKind::Reasoning,
        "thinking",
        &value,
        created_at,
    ));
}

fn kimi_code_content_group(value: &Value, event: &Value) -> String {
    let turn = find_string(value, &["turnId", "turn_id"])
        .or_else(|| find_string(event, &["turnId", "turn_id"]))
        .unwrap_or_default();
    let step = find_string(event, &["step", "stepId", "step_id"]).unwrap_or_default();
    format!("{turn}\n{step}")
}

fn kimi_code_usage_message(path: &Path, index: usize, value: &Value) -> Option<Value> {
    if value.get("usageScope").and_then(Value::as_str) != Some("turn") {
        return None;
    }
    let usage = value.get("usage")?.as_object()?;
    let input_other = usage
        .get("inputOther")
        .and_then(token_count_value)
        .unwrap_or(0);
    let input_cache_read = usage
        .get("inputCacheRead")
        .and_then(token_count_value)
        .unwrap_or(0);
    let input_cache_creation = usage
        .get("inputCacheCreation")
        .and_then(token_count_value)
        .unwrap_or(0);
    let output = usage.get("output").and_then(token_count_value).unwrap_or(0);
    let prompt_tokens = input_other
        .saturating_add(input_cache_read)
        .saturating_add(input_cache_creation);
    let total_tokens = prompt_tokens.saturating_add(output);
    if total_tokens == 0 {
        return None;
    }
    let model = value
        .get("model")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let created_at = find_string(value, &["time", "timestamp", "createdAt"])
        .unwrap_or_else(native_message_timestamp);
    Some(json!({
        "id": native_history_message_id(HistoryAdapter::KimiCode, path, index, 0),
        "role": "metadata",
        "text": "Kimi Code token usage",
        "createdAt": created_at,
        "sourcePath": display_path(path),
        "sourceEventType": "usage.record",
        "model": model,
        "usageScope": "turn",
        "usage": {
            "promptTokens": prompt_tokens,
            "cachedInputTokens": input_cache_read,
            "completionTokens": output,
            "totalTokens": total_tokens,
            "source": "explicit"
        }
    }))
}

fn kimi_code_native_session_id(path: &Path) -> String {
    let agent_id = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .unwrap_or("main");
    let session_id = path
        .ancestors()
        .nth(3)
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .unwrap_or("session");
    if agent_id == "main" {
        session_id.to_string()
    } else {
        format!("{session_id}:{agent_id}")
    }
}

fn history_file_can_exceed_byte_limit(adapter: HistoryAdapter, path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(extension.as_str(), "sqlite" | "sqlite3" | "db" | "vscdb")
        && adapter.accepts_file(path, &extension)
}

fn finalize_history_sessions(sessions: Vec<Value>, scan_config: &HistoryScanConfig) -> Vec<Value> {
    let sessions = merge_delegated_subagent_sessions(sessions);
    let sessions = merge_codex_rollout_lineage_sessions(sessions);
    sessions
        .into_iter()
        .filter(|session| !session_is_delegated_subagent(session))
        .filter(history_session_has_user_authored_message)
        .filter(|session| scan_config.matches_session(session))
        .map(|session| scan_config.compact_session_for_archive_discovery(session))
        .collect()
}

fn dedupe_history_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut seen = BTreeSet::<String>::new();
    sessions
        .into_iter()
        .filter(|session| seen.insert(history_session_dedupe_key(session)))
        .collect()
}

/// Collapse Codex fork/continuation rollouts that share a `forked_from_id` /
/// `parentSessionId` chain into one list entry per lineage root.
fn merge_codex_rollout_lineage_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut codex = Vec::<Value>::new();
    let mut other = Vec::<Value>::new();
    for session in sessions {
        if history_session_adapter_id(&session) == "codex" {
            codex.push(session);
        } else {
            other.push(session);
        }
    }
    if codex.len() < 2 {
        other.extend(codex);
        return other;
    }

    let parents = codex_rollout_lineage_parents(&codex);
    if parents.is_empty() {
        other.extend(codex);
        return other;
    }

    let mut groups = BTreeMap::<String, Vec<Value>>::new();
    for session in codex {
        let native_id = history_session_native_id(&session);
        let root = codex_rollout_lineage_root(&native_id, &parents);
        groups.entry(root).or_default().push(session);
    }

    for (root, members) in groups {
        if members.len() == 1 {
            let mut session = members.into_iter().next().expect("one member");
            annotate_codex_lineage_root(&mut session, &root);
            other.push(session);
            continue;
        }
        other.push(collapse_codex_rollout_lineage_group(root, members));
    }
    other
}

fn codex_rollout_lineage_parents(sessions: &[Value]) -> BTreeMap<String, String> {
    let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
    for session in sessions {
        let native_id = history_session_native_id(session);
        if native_id.is_empty() {
            continue;
        }
        let Some(parent_id) = session
            .get("parentSessionId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
        else {
            continue;
        };
        if parent_id == native_id {
            continue;
        }
        candidates.entry(native_id).or_default().insert(parent_id);
    }
    candidates
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
        .collect()
}

fn codex_rollout_lineage_root(session_id: &str, parents: &BTreeMap<String, String>) -> String {
    if session_id.is_empty() {
        return String::new();
    }
    let mut current = session_id.to_string();
    let mut visited = BTreeSet::<String>::new();
    loop {
        if !visited.insert(current.clone()) {
            return visited
                .into_iter()
                .min()
                .unwrap_or_else(|| session_id.to_string());
        }
        let Some(parent) = parents.get(&current) else {
            return current;
        };
        current.clone_from(parent);
    }
}

fn collapse_codex_rollout_lineage_group(root: String, mut members: Vec<Value>) -> Value {
    members.sort_by(|left, right| {
        session_updated_order_key(left)
            .cmp(&session_updated_order_key(right))
            .then_with(|| history_session_native_id(left).cmp(&history_session_native_id(right)))
    });
    let tip_index = members
        .iter()
        .enumerate()
        .max_by_key(|(index, session)| {
            (
                session_updated_order_key(session),
                history_session_message_count(session),
                *index,
            )
        })
        .map(|(index, _)| index)
        .unwrap_or(0);
    let tip = members[tip_index].clone();
    let messages = merge_codex_lineage_messages(&members);
    let created_at = members
        .iter()
        .filter_map(|session| session.get("createdAt").and_then(Value::as_str))
        .min()
        .unwrap_or_default()
        .to_string();
    let updated_at = members
        .iter()
        .filter_map(|session| session.get("updatedAt").and_then(Value::as_str))
        .max()
        .unwrap_or_default()
        .to_string();
    let member_ids = members
        .iter()
        .map(history_session_native_id)
        .filter(|value| !value.is_empty())
        .collect::<BTreeSet<_>>();

    let mut collapsed = tip;
    if let Some(object) = collapsed.as_object_mut() {
        object.insert("createdAt".to_string(), json!(created_at));
        if !updated_at.is_empty() {
            object.insert("updatedAt".to_string(), json!(updated_at));
        }
        object.insert("messages".to_string(), json!(messages.clone()));
        object.insert("messageCount".to_string(), json!(messages.len()));
        object.insert("lineageRootId".to_string(), json!(root));
        object.insert(
            "lineageSessionIds".to_string(),
            json!(member_ids.into_iter().collect::<Vec<_>>()),
        );
        object.remove("parentSessionId");
        object.remove("delegatedSubagent");
        object.remove("subagentTitle");
    }
    collapsed
}

fn merge_codex_lineage_messages(members: &[Value]) -> Vec<Value> {
    let tip = members.iter().max_by_key(|session| {
        (
            session_updated_order_key(session),
            history_session_message_count(session),
        )
    });
    let tip_count = tip.map(history_session_message_count).unwrap_or(0);
    let max_count = members
        .iter()
        .map(history_session_message_count)
        .max()
        .unwrap_or(0);
    // Codex fork rollouts commonly replay the shared prefix. Prefer the tip
    // transcript when it already carries the richest history.
    if tip_count >= max_count {
        if let Some(messages) = tip
            .and_then(|session| session.get("messages"))
            .and_then(Value::as_array)
        {
            return messages.clone();
        }
    }

    let mut ordered_members = members
        .iter()
        .enumerate()
        .map(|(index, session)| (session_updated_order_key(session), index, session))
        .collect::<Vec<_>>();
    ordered_members.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));

    let mut seen = BTreeSet::<String>::new();
    let mut messages = Vec::<Value>::new();
    for (_, _, session) in ordered_members {
        let Some(items) = session.get("messages").and_then(Value::as_array) else {
            continue;
        };
        for message in items {
            let fingerprint = codex_lineage_message_fingerprint(message);
            if !seen.insert(fingerprint) {
                continue;
            }
            messages.push(message.clone());
        }
    }
    messages.sort_by(|left, right| {
        message_order_key(left)
            .unwrap_or(0)
            .cmp(&message_order_key(right).unwrap_or(0))
            .then_with(|| {
                codex_lineage_message_fingerprint(left)
                    .cmp(&codex_lineage_message_fingerprint(right))
            })
    });
    messages
}

fn codex_lineage_message_fingerprint(message: &Value) -> String {
    let role = message_role(message);
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if matches!(
        role.as_str(),
        "user" | "human" | "assistant" | "agent" | "model"
    ) && !text.trim().is_empty()
    {
        let mut hasher = Sha256::new();
        hasher.update(role.as_bytes());
        hasher.update(b"\n");
        hasher.update(text.as_bytes());
        return format!("thread:{:x}", hasher.finalize());
    }
    let id = message
        .get("id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    if !id.is_empty() {
        return format!("id:{id}");
    }
    let created = message
        .get("createdAt")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let card_title = message
        .get("cardTitle")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(role.as_bytes());
    hasher.update(b"\n");
    hasher.update(created.as_bytes());
    hasher.update(b"\n");
    hasher.update(card_title.as_bytes());
    hasher.update(b"\n");
    hasher.update(text.as_bytes());
    format!("body:{:x}", hasher.finalize())
}

fn annotate_codex_lineage_root(session: &mut Value, root: &str) {
    if root.is_empty() {
        return;
    }
    if let Some(object) = session.as_object_mut() {
        object.insert("lineageRootId".to_string(), json!(root));
    }
}

fn history_session_adapter_id(session: &Value) -> &str {
    session
        .get("adapterId")
        .and_then(Value::as_str)
        .unwrap_or_default()
}

fn history_session_native_id(session: &Value) -> String {
    session
        .get("nativeSessionId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
        .to_string()
}

fn history_session_message_count(session: &Value) -> usize {
    session
        .get("messageCount")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .or_else(|| {
            session
                .get("messages")
                .and_then(Value::as_array)
                .map(Vec::len)
        })
        .unwrap_or(0)
}

fn apply_codex_session_index_titles(params: &Value, sessions: &mut [Value]) {
    let titles = load_codex_session_index_titles(params);
    if titles.is_empty() {
        return;
    }
    for session in sessions.iter_mut() {
        let Some(native_id) = session
            .get("nativeSessionId")
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            continue;
        };
        let Some(title) = titles.get(&native_id) else {
            continue;
        };
        if !meaningful_explicit_title(title) {
            continue;
        }
        if let Some(object) = session.as_object_mut() {
            object.insert("title".to_string(), json!(title_from_text(title)));
        }
    }
}

fn load_codex_session_index_titles(params: &Value) -> HashMap<String, String> {
    let mut candidates = Vec::<PathBuf>::new();
    let roots = history_roots(HistoryAdapter::Codex, params);
    for root in &roots {
        if root.source_kind == "codex-session-index" {
            candidates.push(root.path.clone());
        } else if root.source_kind == "override-root" {
            candidates.push(root.path.join("session_index.jsonl"));
            candidates.push(root.path.join(".codex/session_index.jsonl"));
        }
    }
    if let Some(home) = text_param(params, &["homeDir"]).filter(|value| !value.trim().is_empty()) {
        candidates.push(PathBuf::from(home).join(".codex/session_index.jsonl"));
    }
    if candidates.is_empty() && text_param(params, &["root", "historyRoot", "homeDir"]).is_none() {
        candidates.push(home_dir().join(".codex/session_index.jsonl"));
    }
    for path in candidates {
        let titles = read_codex_session_index_titles_file(&path);
        if !titles.is_empty() {
            return titles;
        }
    }
    HashMap::new()
}

fn read_codex_session_index_titles_file(path: &Path) -> HashMap<String, String> {
    let mut titles = HashMap::<String, String>::new();
    let Ok(raw) = fs::read_to_string(path) else {
        return titles;
    };
    let mut stamped = HashMap::<String, (String, String)>::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let Some(id) = find_string(&value, &["id", "sessionId", "session_id", "thread_id"])
            .filter(|value| !value.trim().is_empty())
        else {
            continue;
        };
        let Some(title) = extract_conversation_title(&value) else {
            continue;
        };
        let updated =
            find_string(&value, &["updated_at", "updatedAt", "timestamp"]).unwrap_or_default();
        match stamped.get(&id) {
            Some((previous, _)) if !updated.is_empty() && previous.as_str() >= updated.as_str() => {
            }
            _ => {
                stamped.insert(id, (updated, title));
            }
        }
    }
    for (id, (_, title)) in stamped {
        titles.insert(id, title);
    }
    titles
}

fn paged_history_sessions(sessions: Vec<Value>, page: &HistoryPageConfig) -> Vec<Value> {
    if page.offset >= sessions.len() {
        return Vec::new();
    }
    let end = page
        .end()
        .map(|end| end.min(sessions.len()))
        .unwrap_or(sessions.len());
    sessions
        .into_iter()
        .skip(page.offset)
        .take(end.saturating_sub(page.offset))
        .collect()
}

fn history_session_dedupe_key(session: &Value) -> String {
    let adapter_id = history_session_adapter_id(session);
    let native_session_id = history_session_native_id(session);
    // Codex rollouts are identity-bound by UUID. Active and archived copies of
    // the same thread must collapse even when sourcePath differs.
    if adapter_id == "codex" && !native_session_id.is_empty() {
        return format!("{adapter_id}\n{native_session_id}");
    }
    let source_path = session
        .get("sourcePath")
        .and_then(Value::as_str)
        .unwrap_or_default();
    format!("{adapter_id}\n{source_path}\n{native_session_id}")
}

fn collect_history_model_names(value: &Value, names: &mut BTreeSet<String>, depth: usize) {
    if depth > 8 {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if is_history_model_key(key) {
                    collect_history_model_name_value(child, names);
                    continue;
                }
                if matches!(
                    key.as_str(),
                    "messages" | "usage" | "metadata" | "payload" | "request" | "response"
                ) {
                    collect_history_model_names(child, names, depth + 1);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_history_model_names(item, names, depth + 1);
            }
        }
        _ => {}
    }
}

fn collect_history_model_name_value(value: &Value, names: &mut BTreeSet<String>) {
    match value {
        Value::String(value) => {
            if let Some(name) = sanitize_history_model_name(value) {
                names.insert(name);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_history_model_name_value(item, names);
            }
        }
        Value::Object(object) => {
            for key in [
                "displayName",
                "display_name",
                "label",
                "name",
                "model",
                "modelName",
                "model_name",
                "id",
                "modelId",
                "model_id",
            ] {
                if let Some(name) = object
                    .get(key)
                    .and_then(Value::as_str)
                    .and_then(sanitize_history_model_name)
                {
                    names.insert(name);
                    return;
                }
            }
        }
        _ => {}
    }
}

fn is_history_model_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>();
    matches!(
        normalized.as_str(),
        "model" | "modelid" | "modelname" | "modellabel" | "currentmodel" | "selectedmodel"
    )
}

fn sanitize_history_model_name(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 160
        || trimmed.contains('\n')
        || trimmed.contains('\r')
        || trimmed.starts_with('{')
        || trimmed.starts_with('[')
        || trimmed.starts_with('$')
        || trimmed.starts_with("http://")
        || trimmed.starts_with("https://")
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn merge_delegated_subagent_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut indexed_sessions = sessions
        .into_iter()
        .enumerate()
        .map(|(index, session)| (index, session_order_key(&session, index), session))
        .collect::<Vec<_>>();

    // Fold explicit parent/child lineages from the leaves upward so nested
    // workers remain inside their direct parent before that parent is folded.
    loop {
        let native_ids = indexed_sessions
            .iter()
            .enumerate()
            .filter_map(|(index, (_, _, session))| {
                session
                    .get("nativeSessionId")
                    .and_then(Value::as_str)
                    .map(|id| (id.to_string(), index))
            })
            .collect::<HashMap<_, _>>();
        let child =
            indexed_sessions
                .iter()
                .enumerate()
                .find_map(|(child_index, (_, _, session))| {
                    if !session_is_delegated_subagent(session) {
                        return None;
                    }
                    let parent_id = session.get("parentSessionId")?.as_str()?;
                    let parent_index = *native_ids.get(parent_id)?;
                    (parent_index != child_index).then_some((child_index, parent_index))
                });
        let Some((child_index, parent_index)) = child else {
            break;
        };
        let (_, _, child_session) = indexed_sessions.remove(child_index);
        let adjusted_parent_index = if child_index < parent_index {
            parent_index - 1
        } else {
            parent_index
        };
        if let Some(card) = subagent_card_from_session(&child_session) {
            insert_subagent_card_into_session(&mut indexed_sessions[adjusted_parent_index].2, card);
        }
    }

    let mut main_sessions = Vec::<(usize, i128, Value)>::new();
    let mut subagent_cards = Vec::<(usize, i128, Value)>::new();

    for (index, order_key, session) in indexed_sessions {
        if let Some(card) = subagent_card_from_session(&session) {
            subagent_cards.push((index, order_key, card));
        } else {
            main_sessions.push((index, order_key, session));
        }
    }

    if main_sessions.is_empty() {
        return Vec::new();
    }

    for (card_index, card_order_key, card) in subagent_cards {
        if let Some(parent_index) =
            nearest_main_session_index(&main_sessions, card_index, card_order_key)
        {
            insert_subagent_card_into_session(&mut main_sessions[parent_index].2, card);
        }
    }

    main_sessions
        .into_iter()
        .map(|(_, _, session)| session)
        .collect()
}

fn nearest_main_session_index(
    main_sessions: &[(usize, i128, Value)],
    card_index: usize,
    card_order_key: i128,
) -> Option<usize> {
    main_sessions
        .iter()
        .enumerate()
        .min_by_key(|(_, (main_index, main_order_key, _))| {
            (
                (*main_order_key - card_order_key).abs(),
                main_index.abs_diff(card_index),
            )
        })
        .map(|(index, _)| index)
}

fn insert_subagent_card_into_session(session: &mut Value, card: Value) {
    let Some(object) = session.as_object_mut() else {
        return;
    };
    let Some(message_count) = object
        .get_mut("messages")
        .and_then(Value::as_array_mut)
        .map(|messages| {
            let card_order_key = message_order_key(&card).unwrap_or(i128::MAX);
            let insert_at = messages
                .iter()
                .position(|message| {
                    message_order_key(message)
                        .map(|order_key| order_key > card_order_key)
                        .unwrap_or(false)
                })
                .unwrap_or(messages.len());
            messages.insert(insert_at, card);
            messages.len()
        })
    else {
        return;
    };
    object.insert("messageCount".to_string(), json!(message_count));
}

fn subagent_card_from_session(session: &Value) -> Option<Value> {
    let messages = session.get("messages").and_then(Value::as_array)?;
    let prompt = messages
        .iter()
        .find(|message| message_role(message) == "subagent_prompt");
    if prompt.is_none() && !session_is_explicit_delegated_subagent(session) {
        return None;
    }
    let title = session
        .get("subagentTitle")
        .and_then(Value::as_str)
        .or_else(|| prompt.and_then(|message| message.get("subagentTitle").and_then(Value::as_str)))
        .filter(|title| !title.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "Subagent task".to_string());
    let child_messages = messages
        .iter()
        .filter(|message| subagent_card_child_message_is_visible(message))
        .cloned()
        .collect::<Vec<_>>();
    if child_messages.is_empty() {
        return None;
    }
    let preview = child_messages
        .iter()
        .rev()
        .filter_map(|message| message.get("text").and_then(Value::as_str))
        .find(|text| !text.trim().is_empty())
        .map(subagent_card_preview_text)
        .unwrap_or_else(|| title.clone());
    let created_at = prompt
        .and_then(|message| message.get("createdAt").and_then(Value::as_str))
        .or_else(|| {
            child_messages
                .first()
                .and_then(|message| message.get("createdAt").and_then(Value::as_str))
        })
        .unwrap_or_default()
        .to_string();
    let source_path = session
        .get("sourcePath")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let card_id = session
        .get("id")
        .and_then(Value::as_str)
        .map(|id| format!("{}::subagent-card", id))
        .unwrap_or_else(|| "subagent-card".to_string());
    Some(json!({
        "id": card_id,
        "role": "subagent",
        "text": preview,
        "createdAt": created_at,
        "sourcePath": source_path,
        "cardType": "subagent",
        "cardTitle": title,
        "collapsed": true,
        "messages": child_messages
    }))
}

fn subagent_card_child_message_is_visible(message: &Value) -> bool {
    let role = message_role(message);
    !matches!(
        role.as_str(),
        "subagent_prompt" | "system" | "developer" | "metadata" | "tool" | "function"
    ) && message
        .get("text")
        .and_then(Value::as_str)
        .map(|text| !text.trim().is_empty())
        .unwrap_or(false)
}

fn subagent_card_preview_text(text: &str) -> String {
    let preview = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    let mut out = preview.chars().take(180).collect::<String>();
    if preview.chars().count() > 180 {
        out.push_str("...");
    }
    out
}

fn session_is_delegated_subagent(session: &Value) -> bool {
    session_is_explicit_delegated_subagent(session)
        || session
            .get("messages")
            .and_then(Value::as_array)
            .map(|messages| {
                messages
                    .iter()
                    .any(|message| message_role(message) == "subagent_prompt")
            })
            .unwrap_or(false)
}

fn session_is_explicit_delegated_subagent(session: &Value) -> bool {
    session
        .get("delegatedSubagent")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && session
            .get("parentSessionId")
            .and_then(Value::as_str)
            .map(|id| !id.trim().is_empty())
            .unwrap_or(false)
}

fn message_role(message: &Value) -> String {
    message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn session_order_key(session: &Value, fallback_index: usize) -> i128 {
    session
        .get("messages")
        .and_then(Value::as_array)
        .and_then(|messages| messages.iter().filter_map(message_order_key).next())
        .or_else(|| {
            session
                .get("createdAt")
                .and_then(Value::as_str)
                .and_then(history_time_order_key)
        })
        .or_else(|| {
            session
                .get("updatedAt")
                .and_then(Value::as_str)
                .and_then(history_time_order_key)
        })
        .unwrap_or(fallback_index as i128)
}

fn message_order_key(message: &Value) -> Option<i128> {
    message.get("createdAt").and_then(history_value_order_key)
}

fn history_value_order_key(value: &Value) -> Option<i128> {
    match value {
        Value::String(text) => history_time_order_key(text),
        Value::Number(number) => number
            .as_i64()
            .map(i128::from)
            .or_else(|| number.as_u64().map(|value| value as i128))
            .or_else(|| number.as_f64().map(|value| value as i128)),
        _ => None,
    }
}

fn history_time_order_key(value: &str) -> Option<i128> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(timestamp) = OffsetDateTime::parse(trimmed, &Rfc3339) {
        return Some(
            timestamp.unix_timestamp() as i128 * 1_000_000_000 + timestamp.nanosecond() as i128,
        );
    }
    trimmed.parse::<i128>().ok()
}

fn sort_sessions_by_updated_at(sessions: &mut [Value]) {
    sessions.sort_by(|left, right| {
        session_updated_order_key(right)
            .cmp(&session_updated_order_key(left))
            .then_with(|| history_session_dedupe_key(left).cmp(&history_session_dedupe_key(right)))
    });
}

fn session_updated_order_key(session: &Value) -> i128 {
    session
        .get("messages")
        .and_then(Value::as_array)
        .and_then(|messages| messages.iter().filter_map(message_order_key).max())
        .or_else(|| session.get("updatedAt").and_then(history_value_order_key))
        .or_else(|| session.get("createdAt").and_then(history_value_order_key))
        .or_else(|| {
            session
                .get("messages")
                .and_then(Value::as_array)
                .and_then(|messages| messages.iter().rev().filter_map(message_order_key).next())
        })
        .unwrap_or(0)
}

fn emit_json_line(value: &Value) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn excluded_history_path_reason(path: &Path) -> Option<&'static str> {
    let components = path
        .components()
        .filter_map(|component| component.as_os_str().to_str())
        .collect::<Vec<_>>();
    if components
        .windows(2)
        .any(|window| window == [".system_generated", "tasks"])
    {
        return Some("excluded_generated_task_logs");
    }
    let excluded = components.iter().any(|name| {
        matches!(
            *name,
            "node_modules" | ".git" | "target" | "build" | "dist" | ".next"
        )
    });
    if excluded {
        Some("excluded_non_history_directory")
    } else {
        None
    }
}

fn parse_jsonl_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Vec<Value> {
    if adapter == HistoryAdapter::Copilot {
        if let Some(session) = parse_copilot_transcript_session(path, source_kind, metadata) {
            return vec![session];
        }
    }

    if adapter == HistoryAdapter::Codex {
        if let Some(sessions) =
            parse_codex_rollout_sessions(path, source_kind, metadata, scan_config.clone())
        {
            return sessions;
        }
    }

    if adapter == HistoryAdapter::Pi {
        if let Some(session) = parse_pi_session(path, source_kind, metadata) {
            return vec![session];
        }
    }

    let mut grouped = Vec::<(String, Vec<Value>)>::new();
    if scan_config.archive_mode {
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(_) => return Vec::new(),
        };
        let reader = BufReader::new(file);
        for (index, line) in reader.lines().enumerate() {
            let Ok(line) = line else {
                continue;
            };
            push_jsonl_message(adapter, path, index, &line, &mut grouped);
        }
    } else {
        let raw = match fs::read_to_string(path) {
            Ok(raw) => raw,
            Err(_) => return Vec::new(),
        };
        for (index, line) in raw.lines().enumerate() {
            push_jsonl_message(adapter, path, index, line, &mut grouped);
        }
    }
    grouped
        .into_iter()
        .map(|(native_session_id, messages)| {
            session_from_messages(
                adapter,
                path,
                metadata,
                source_kind,
                native_session_id,
                messages,
            )
        })
        .collect()
}

fn parse_pi_session(path: &Path, source_kind: &str, metadata: &fs::Metadata) -> Option<Value> {
    let raw = fs::read_to_string(path).ok()?;
    let mut native_session_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .and_then(|stem| stem.rsplit_once('_').map(|(_, id)| id.to_string()))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "pi-session".to_string());
    let mut title = None::<String>;
    let mut messages = Vec::<Value>::new();

    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let entry_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match entry_type {
            "session" => {
                if let Some(session_id) = value
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                {
                    native_session_id = session_id.to_string();
                }
            }
            "session_info" => {
                if let Some(name) = value
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                {
                    title = Some(name.to_string());
                }
            }
            "message" => {
                let Some(message) = value.get("message") else {
                    continue;
                };
                let role = message
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let normalized_role = match role {
                    "user" => "user",
                    "assistant" => "agent",
                    "toolResult" => "tool",
                    other if !other.is_empty() => other,
                    _ => continue,
                };
                if role == "assistant" {
                    if let Some(blocks) = message.get("content").and_then(Value::as_array) {
                        for (block_index, block) in blocks.iter().enumerate() {
                            let block_type =
                                block.get("type").and_then(Value::as_str).unwrap_or("");
                            if block_type == "thinking" {
                                if let Some(text) = block.get("thinking").and_then(Value::as_str) {
                                    if let Some(message) = plain_history_message(
                                        HistoryAdapter::Pi,
                                        path,
                                        index,
                                        block_index,
                                        "reasoning",
                                        text,
                                        extract_timestamp(&value),
                                    ) {
                                        messages.push(message);
                                    }
                                }
                                continue;
                            }
                            if block_type == "toolCall" {
                                messages.push(structured_history_message(
                                    HistoryAdapter::Pi,
                                    path,
                                    index,
                                    block_index,
                                    HistoryMessageKind::ToolCall,
                                    "tool",
                                    block,
                                    extract_timestamp(&value),
                                ));
                                continue;
                            }
                            if let Some(text) = extract_text(block) {
                                if let Some(message) = plain_history_message(
                                    HistoryAdapter::Pi,
                                    path,
                                    index,
                                    block_index,
                                    normalized_role,
                                    &text,
                                    extract_timestamp(&value),
                                ) {
                                    messages.push(message);
                                }
                            }
                        }
                        continue;
                    }
                }
                if let Some(text) = extract_text(message).or_else(|| extract_text(&value)) {
                    if let Some(message) = plain_history_message(
                        HistoryAdapter::Pi,
                        path,
                        index,
                        0,
                        normalized_role,
                        &text,
                        extract_timestamp(&value).or_else(|| extract_timestamp(message)),
                    ) {
                        messages.push(message);
                    }
                }
            }
            _ => {}
        }
    }

    if messages.is_empty() {
        return None;
    }
    Some(session_from_messages_with_title(
        HistoryAdapter::Pi,
        path,
        metadata,
        source_kind,
        native_session_id,
        messages,
        title,
    ))
}

fn parse_copilot_transcript_session(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Option<Value> {
    let raw = fs::read_to_string(path).ok()?;
    let mut native_session_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "copilot-transcript".to_string());
    let mut messages = Vec::<Value>::new();

    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if event_type == "session.start" {
            if let Some(session_id) = value
                .get("data")
                .and_then(|data| data.get("sessionId"))
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
            {
                native_session_id = session_id.to_string();
            }
            continue;
        }
        let structured_kind = history_message_kind_from_semantic(event_type);
        if structured_kind != HistoryMessageKind::Text {
            messages.push(structured_history_message(
                HistoryAdapter::Copilot,
                path,
                index,
                0,
                structured_kind,
                event_type,
                value.get("data").unwrap_or(&value),
                extract_timestamp(&value),
            ));
            continue;
        }
        let role = match event_type {
            "user.message" => "user",
            "assistant.message" => "agent",
            _ => continue,
        };
        let data = value.get("data").unwrap_or(&value);
        let text = data
            .get("content")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| extract_text(data))
            .unwrap_or_default();
        let Some(text) = clean_native_message_text(HistoryAdapter::Copilot, role, &text) else {
            continue;
        };
        let created_at = extract_timestamp(&value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        });
        messages.push(json!({
            "id": message_id(HistoryAdapter::Copilot.id(), path, index),
            "role": role,
            "text": text,
            "createdAt": created_at,
            "sourcePath": display_path(path),
            "sourceEventType": event_type
        }));
    }

    if messages.is_empty() {
        return None;
    }
    Some(session_from_messages(
        HistoryAdapter::Copilot,
        path,
        metadata,
        source_kind,
        native_session_id,
        messages,
    ))
}

#[derive(Debug)]
struct CodexRolloutGroup {
    session_id: String,
    parent_session_id: Option<String>,
    subagent_title: Option<String>,
    is_subagent: bool,
    messages: Vec<Value>,
    cwd: Option<String>,
    matched_terms: BTreeSet<String>,
    message_count: usize,
    preview_count: usize,
}

fn parse_codex_rollout_sessions(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Option<Vec<Value>> {
    let mut groups = Vec::<CodexRolloutGroup>::new();
    let mut current_session_id = rollout_session_id_from_filename(path);
    let mut saw_rollout_record = false;

    if scan_config.archive_mode {
        let file = fs::File::open(path).ok()?;
        let reader = BufReader::new(file);
        for (index, line) in reader.lines().enumerate() {
            let Ok(line) = line else {
                continue;
            };
            parse_codex_rollout_line(
                path,
                index,
                &line,
                &scan_config,
                &mut current_session_id,
                &mut saw_rollout_record,
                &mut groups,
            );
        }
    } else {
        let raw = fs::read_to_string(path).ok()?;
        for (index, line) in raw.lines().enumerate() {
            parse_codex_rollout_line(
                path,
                index,
                line,
                &scan_config,
                &mut current_session_id,
                &mut saw_rollout_record,
                &mut groups,
            );
        }
    }

    if !saw_rollout_record {
        return None;
    }

    Some(
        groups
            .into_iter()
            .filter(|group| {
                !group.messages.is_empty()
                    && (!scan_config.has_match_filters() || !group.matched_terms.is_empty())
            })
            .map(|group| {
                let message_count = group.message_count.max(group.messages.len());
                let mut session = session_from_messages(
                    HistoryAdapter::Codex,
                    path,
                    metadata,
                    source_kind,
                    group.session_id,
                    group.messages,
                );
                if let Some(object) = session.as_object_mut() {
                    object.insert("messageCount".to_string(), json!(message_count));
                    if scan_config.has_match_filters() {
                        object.insert("archiveDiscoveryHasConversation".to_string(), json!(true));
                        object.insert(
                            "archiveDiscoveryMatchedTerms".to_string(),
                            json!(group.matched_terms.into_iter().collect::<Vec<_>>()),
                        );
                        object.insert(
                            "messagesTruncatedForArchiveDiscovery".to_string(),
                            json!(true),
                        );
                    }
                    if let Some(cwd) = group.cwd {
                        object.insert("workingDirectory".to_string(), json!(cwd));
                    }
                    if let Some(parent_session_id) = group.parent_session_id {
                        object.insert("parentSessionId".to_string(), json!(parent_session_id));
                    }
                    if group.is_subagent {
                        object.insert("delegatedSubagent".to_string(), json!(true));
                    }
                    if let Some(title) = group.subagent_title {
                        object.insert("subagentTitle".to_string(), json!(title));
                    }
                }
                session
            })
            .collect(),
    )
}

fn parse_codex_rollout_line(
    path: &Path,
    index: usize,
    line: &str,
    scan_config: &HistoryScanConfig,
    current_session_id: &mut Option<String>,
    saw_rollout_record: &mut bool,
    groups: &mut Vec<CodexRolloutGroup>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
        return;
    };
    let Some(event_type) = value.get("type").and_then(Value::as_str) else {
        return;
    };
    let Some(payload) = value.get("payload") else {
        return;
    };
    if !matches!(
        event_type,
        "session_meta" | "turn_context" | "response_item" | "event_msg"
    ) {
        return;
    }
    *saw_rollout_record = true;

    if event_type == "session_meta" {
        if let Some(session_id) = find_string(payload, &["id", "sessionId", "session_id"])
            .filter(|value| !value.trim().is_empty())
        {
            *current_session_id = Some(session_id);
        }
    }

    let session_id = current_session_id
        .clone()
        .unwrap_or_else(|| "file".to_string());
    let cwd = find_string(payload, &["cwd", "workingDirectory", "projectPath"])
        .filter(|value| !value.trim().is_empty());

    if event_type == "session_meta" {
        update_codex_rollout_group_lineage(groups, &session_id, payload);
    }

    if let Some(message) = codex_rollout_message(path, index, event_type, payload, &value) {
        push_codex_rollout_message(groups, session_id, message, cwd, scan_config);
    } else if cwd.is_some() {
        update_codex_rollout_group_cwd(groups, session_id, cwd);
    }
}

fn update_codex_rollout_group_cwd(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: String,
    cwd: Option<String>,
) {
    if let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    {
        if group.cwd.is_none() {
            group.cwd = cwd;
        }
        return;
    }
    groups.push(CodexRolloutGroup {
        session_id,
        parent_session_id: None,
        subagent_title: None,
        is_subagent: false,
        messages: Vec::new(),
        cwd,
        matched_terms: BTreeSet::new(),
        message_count: 0,
        preview_count: 0,
    });
}

fn update_codex_rollout_group_lineage(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: &str,
    payload: &Value,
) {
    if !groups.iter().any(|group| group.session_id == session_id) {
        update_codex_rollout_group_cwd(groups, session_id.to_string(), None);
    }
    let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    else {
        return;
    };
    group.parent_session_id = find_nested_string(
        payload,
        &[
            "forked_from_id",
            "forkedFromId",
            "parent_session_id",
            "parentSessionId",
            "parent_thread_id",
            "parentThreadId",
        ],
        0,
    )
    .filter(|parent_id| parent_id != session_id);
    group.is_subagent = contains_nested_key(payload, "subagent", 0)
        || contains_nested_key(payload, "thread_spawn", 0)
        || contains_nested_key(payload, "threadSpawn", 0);
    group.subagent_title = find_nested_string(
        payload,
        &["agent_nickname", "agentNickname", "agent_role", "agentRole"],
        0,
    );
}

fn find_nested_string(value: &Value, keys: &[&str], depth: usize) -> Option<String> {
    if depth > 8 {
        return None;
    }
    match value {
        Value::Object(object) => {
            for key in keys {
                if let Some(text) = object.get(*key).and_then(Value::as_str) {
                    if !text.trim().is_empty() {
                        return Some(text.to_string());
                    }
                }
            }
            object
                .values()
                .find_map(|child| find_nested_string(child, keys, depth + 1))
        }
        Value::Array(items) => items
            .iter()
            .find_map(|child| find_nested_string(child, keys, depth + 1)),
        _ => None,
    }
}

fn contains_nested_key(value: &Value, needle: &str, depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match value {
        Value::Object(object) => {
            object.contains_key(needle)
                || object
                    .values()
                    .any(|child| contains_nested_key(child, needle, depth + 1))
        }
        Value::Array(items) => items
            .iter()
            .any(|child| contains_nested_key(child, needle, depth + 1)),
        _ => false,
    }
}

fn push_codex_rollout_message(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: String,
    message: Value,
    cwd: Option<String>,
    scan_config: &HistoryScanConfig,
) {
    let matched_terms = codex_rollout_message_matched_terms(&message, cwd.as_deref(), scan_config);
    if let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    {
        if group.cwd.is_none() {
            group.cwd = cwd;
        }
        push_codex_rollout_message_into_group(group, message, matched_terms, scan_config);
        return;
    }
    let mut group = CodexRolloutGroup {
        session_id,
        parent_session_id: None,
        subagent_title: None,
        is_subagent: false,
        messages: Vec::new(),
        cwd,
        matched_terms: BTreeSet::new(),
        message_count: 0,
        preview_count: 0,
    };
    push_codex_rollout_message_into_group(&mut group, message, matched_terms, scan_config);
    groups.push(group);
}

fn push_codex_rollout_message_into_group(
    group: &mut CodexRolloutGroup,
    message: Value,
    matched_terms: Vec<String>,
    scan_config: &HistoryScanConfig,
) {
    let is_conversation = history_message_is_matchable(&message);
    if is_conversation {
        group.message_count += 1;
    }
    for term in matched_terms {
        group.matched_terms.insert(term);
    }
    if !scan_config.has_match_filters() {
        group.messages.push(message);
        return;
    }
    if !is_conversation {
        return;
    }
    let is_match = !group.matched_terms.is_empty()
        && codex_rollout_message_matched_terms(&message, group.cwd.as_deref(), scan_config)
            .into_iter()
            .any(|term| group.matched_terms.contains(&term));
    if is_match || group.preview_count < ARCHIVE_DISCOVERY_PREVIEW_MESSAGES {
        if !is_match {
            group.preview_count += 1;
        }
        group
            .messages
            .push(truncate_codex_rollout_preview_message(message));
    }
}

fn codex_rollout_message_matched_terms(
    message: &Value,
    cwd: Option<&str>,
    scan_config: &HistoryScanConfig,
) -> Vec<String> {
    if !scan_config.has_match_filters() || !history_message_is_matchable(message) {
        return Vec::new();
    }
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let path_text = cwd.unwrap_or_default();
    scan_config.matched_terms_in_text_and_path(text, path_text)
}

fn truncate_codex_rollout_preview_message(mut message: Value) -> Value {
    if let Some(object) = message.as_object_mut() {
        if let Some(text) = object.get("text").and_then(Value::as_str) {
            if text.chars().count() > ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS {
                object.insert(
                    "text".to_string(),
                    json!(format!(
                        "{}...",
                        text.chars()
                            .take(ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS)
                            .collect::<String>()
                    )),
                );
            }
        }
    }
    message
}

fn codex_rollout_message(
    path: &Path,
    index: usize,
    event_type: &str,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    match event_type {
        "session_meta" | "turn_context" => None,
        "response_item" => codex_response_item_message(path, index, payload, raw_value),
        "event_msg" => codex_event_message(path, index, payload, raw_value),
        _ => None,
    }
}

fn codex_event_message(
    path: &Path,
    index: usize,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized = normalize_history_message_semantic(item_type);
    if normalized.ends_with("-delta")
        || matches!(
            normalized.as_str(),
            "agent-message" | "user-message" | "task-started" | "task-complete"
        )
    {
        return None;
    }
    let kind = if matches!(
        normalized.as_str(),
        "token-count" | "usage" | "turn-metadata"
    ) {
        HistoryMessageKind::Metadata
    } else if matches!(normalized.as_str(), "turn-aborted" | "stream-error") {
        HistoryMessageKind::Error
    } else {
        history_message_kind_from_semantic(item_type)
    };
    if matches!(kind, HistoryMessageKind::Text | HistoryMessageKind::Event)
        && normalized != "warning"
    {
        return None;
    }
    Some(structured_history_message(
        HistoryAdapter::Codex,
        path,
        index,
        0,
        kind,
        item_type,
        payload,
        extract_timestamp(raw_value),
    ))
}

fn codex_response_item_message(
    path: &Path,
    index: usize,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let structured_kind = history_message_kind_from_semantic(item_type);
    if structured_kind != HistoryMessageKind::Text {
        return Some(structured_history_message(
            HistoryAdapter::Codex,
            path,
            index,
            0,
            structured_kind,
            item_type,
            payload,
            extract_timestamp(raw_value),
        ));
    }
    let text = match item_type {
        _ => payload
            .get("content")
            .or_else(|| payload.get("text"))
            .or_else(|| payload.get("summary"))
            .and_then(extract_text),
    }?;
    let role = extract_role(payload);
    if let Some(mut message) = delegated_subagent_prompt_message(
        HistoryAdapter::Codex,
        path,
        index,
        &role,
        &text,
        extract_timestamp(raw_value),
    ) {
        if let Some(object) = message.as_object_mut() {
            object.insert("sourceEventType".to_string(), json!("response_item"));
            object.insert("sourceItemType".to_string(), json!(item_type));
        }
        return Some(message);
    }
    let text = clean_native_message_text(HistoryAdapter::Codex, &role, &text)?;
    if metadata_like_text(&text) {
        return None;
    }
    let mut message = json!({
        "id": message_id(HistoryAdapter::Codex.id(), path, index),
        "role": role,
        "text": text,
        "createdAt": extract_timestamp(raw_value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        }),
        "sourcePath": display_path(path),
        "sourceEventType": "response_item",
        "sourceItemType": item_type
    });
    if let Some(usage) = extract_token_usage(payload).or_else(|| extract_token_usage(raw_value)) {
        if let Some(object) = message.as_object_mut() {
            object.insert("usage".to_string(), usage);
        }
    }
    Some(message)
}

pub(crate) fn codex_usage_estimate_message(value: &Value) -> Option<(String, String)> {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return None;
    }
    let payload = value.get("payload")?;
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if matches!(
        item_type,
        "function_call" | "function_call_output" | "reasoning"
    ) {
        return None;
    }
    let text = payload
        .get("content")
        .or_else(|| payload.get("text"))
        .or_else(|| payload.get("summary"))
        .and_then(extract_text)?;
    let role = extract_role(payload);
    let text = clean_native_message_text(HistoryAdapter::Codex, &role, &text)?;
    if metadata_like_text(&text) {
        return None;
    }
    Some((role, text))
}

fn rollout_session_id_from_filename(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let parts = stem.split('-').collect::<Vec<_>>();
    if parts.len() < 5 {
        return None;
    }
    for window in parts.windows(5) {
        let candidate = window.join("-");
        if looks_like_uuid(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn looks_like_uuid(value: &str) -> bool {
    let parts = value.split('-').collect::<Vec<_>>();
    let lengths = [8usize, 4, 4, 4, 12];
    parts.len() == lengths.len()
        && parts.iter().zip(lengths).all(|(part, length)| {
            part.len() == length && part.chars().all(|ch| ch.is_ascii_hexdigit())
        })
}

fn push_jsonl_message(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    line: &str,
    grouped: &mut Vec<(String, Vec<Value>)>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        let session_id = extract_native_session_id(&value).unwrap_or_else(|| "file".to_string());
        for message in messages_from_json(adapter, path, index, &value) {
            push_grouped_message(grouped, session_id.clone(), message);
        }
    }
}

fn parse_json_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return Vec::new(),
    };
    let value = match serde_json::from_str::<Value>(&raw) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let sessions = collect_explicit_json_sessions(adapter, path, metadata, source_kind, &value);
    if !sessions.is_empty() {
        return sessions;
    }
    let mut messages = Vec::<Value>::new();
    collect_messages_from_value(adapter, path, &value, &mut messages);
    if messages.is_empty() {
        return Vec::new();
    }
    vec![session_from_messages_with_title(
        adapter,
        path,
        metadata,
        source_kind,
        extract_native_session_id(&value).unwrap_or_else(|| "file".to_string()),
        messages,
        extract_conversation_title(&value),
    )]
}

fn parse_text_session(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return Vec::new(),
    };
    if raw.trim().is_empty() || !looks_like_text_conversation(&raw) {
        return Vec::new();
    }
    let created_at = system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH));
    let messages = vec![json!({
        "id": message_id(adapter.id(), path, 0),
        "role": "transcript",
        "text": raw,
        "createdAt": created_at,
        "sourcePath": display_path(path)
    })];
    vec![session_from_messages(
        adapter,
        path,
        metadata,
        source_kind,
        "file".to_string(),
        messages,
    )]
}

fn parse_sqlite_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Vec<Value> {
    let mut connection = match Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_URI
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(connection) => connection,
        Err(_) => return Vec::new(),
    };
    if matches!(adapter, HistoryAdapter::OpenCode | HistoryAdapter::KiloCode) {
        let precise_sessions =
            parse_openagent_sqlite_sessions(adapter, path, source_kind, metadata, &mut connection);
        if !precise_sessions.is_empty() {
            return precise_sessions;
        }
    }
    if matches!(adapter, HistoryAdapter::Cursor) {
        let precise_sessions =
            parse_cursor_sqlite_sessions(path, source_kind, metadata, &mut connection);
        if !precise_sessions.is_empty() {
            return precise_sessions;
        }
    }
    let mut sessions = Vec::<Value>::new();
    let mut table_statement = match connection
        .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    {
        Ok(statement) => statement,
        Err(_) => return sessions,
    };
    let table_names = table_statement
        .query_map([], |row| row.get::<_, String>(0))
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|name| adapter.sqlite_table_may_hold_history(name))
        .collect::<Vec<_>>();

    for table in table_names {
        let mut grouped = Vec::<(String, Vec<Value>)>::new();
        let mut total_index = 0usize;
        let mut offset = 0usize;
        loop {
            let limit = if scan_config.archive_mode {
                ARCHIVE_SQLITE_PAGE_ROWS
            } else {
                MAX_SQLITE_ROWS_PER_TABLE
            };
            let query = format!(
                "SELECT * FROM \"{}\" LIMIT {} OFFSET {}",
                table.replace('"', "\"\""),
                limit,
                offset
            );
            let mut statement = match connection.prepare(&query) {
                Ok(statement) => statement,
                Err(_) => break,
            };
            let column_names = statement
                .column_names()
                .iter()
                .map(|name| name.to_string())
                .collect::<Vec<_>>();
            let rows = match statement.query_map([], |row| {
                let mut fields = Vec::<(String, String)>::new();
                for index in 0..column_names.len() {
                    if let Ok(value) = row.get_ref(index).map(sqlite_value_text) {
                        if value.trim().is_empty() {
                            continue;
                        }
                        fields.push((column_names[index].clone(), value));
                    }
                }
                Ok(fields)
            }) {
                Ok(rows) => rows,
                Err(_) => break,
            };
            let page = rows.filter_map(Result::ok).collect::<Vec<_>>();
            let page_len = page.len();
            for fields in page {
                let index = total_index;
                total_index += 1;
                let row_text = fields
                    .iter()
                    .map(|(name, value)| format!("{}: {}", name, value))
                    .collect::<Vec<_>>()
                    .join("\n");
                let row_key = sqlite_row_key(&fields);
                if !adapter.sqlite_row_may_hold_history(&table, row_key.as_deref(), &row_text) {
                    continue;
                }
                let source_fields = sqlite_fields_json(&fields);
                let session_id = row_key
                    .clone()
                    .unwrap_or_else(|| format!("{}:{}", table, index));
                let row_key_value = row_key.clone().unwrap_or_default();
                let mut row_messages = Vec::<Value>::new();
                if let Some(json_value) = extract_json_from_text(&row_text) {
                    collect_messages_from_value(adapter, path, &json_value, &mut row_messages);
                }
                if row_messages.is_empty() {
                    row_messages.push(json!({
                        "id": message_id(adapter.id(), path, index),
                        "role": "record",
                        "text": row_text,
                        "createdAt": system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH)),
                        "sourcePath": display_path(path),
                        "sourceTable": table,
                        "sourceKey": row_key_value.clone(),
                        "sourceFields": source_fields.clone()
                    }));
                }
                for mut message in row_messages {
                    if let Some(object) = message.as_object_mut() {
                        object
                            .entry("sourceTable".to_string())
                            .or_insert_with(|| json!(table.clone()));
                        object
                            .entry("sourceKey".to_string())
                            .or_insert_with(|| json!(row_key_value.clone()));
                        object
                            .entry("sourceFields".to_string())
                            .or_insert_with(|| source_fields.clone());
                    }
                    push_grouped_message(&mut grouped, session_id.clone(), message);
                }
            }
            if !scan_config.archive_mode || page_len < limit {
                break;
            }
            offset += limit;
        }
        for (native_session_id, messages) in grouped {
            sessions.push(session_from_messages(
                adapter,
                path,
                metadata,
                source_kind,
                native_session_id,
                messages,
            ));
        }
    }
    sessions
}

#[derive(Clone, Debug)]
struct OpenAgentSessionMeta {
    id: String,
    title: Option<String>,
    directory: Option<String>,
    path: Option<String>,
    agent: Option<String>,
    model: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    usage: Option<Value>,
}

fn parse_cursor_sqlite_sessions(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    connection: &mut Connection,
) -> Vec<Value> {
    let transaction = match connection.transaction_with_behavior(TransactionBehavior::Deferred) {
        Ok(transaction) => transaction,
        Err(_) => return Vec::new(),
    };
    if !sqlite_table_exists(&transaction, "cursorDiskKV") {
        return Vec::new();
    }

    let composers = cursor_composer_rows(&transaction);
    if composers.is_empty() {
        return Vec::new();
    }

    let mut sessions = Vec::new();
    for composer in composers {
        let bubble_ids = if composer.bubble_ids.is_empty() {
            cursor_bubble_ids_for_composer(&transaction, &composer.id)
        } else {
            composer.bubble_ids.clone()
        };
        if bubble_ids.is_empty() {
            continue;
        }

        let mut messages = Vec::new();
        for bubble_id in bubble_ids {
            let Some(raw) = cursor_disk_kv_json(
                &transaction,
                &format!("bubbleId:{}:{}", composer.id, bubble_id),
            ) else {
                continue;
            };
            if let Some(message) =
                cursor_message_from_bubble(&raw, &composer.model, path, messages.len())
            {
                messages.push(message);
            }
        }
        if messages.is_empty() {
            continue;
        }

        let mut session = session_from_messages_with_title(
            HistoryAdapter::Cursor,
            path,
            metadata,
            source_kind,
            composer.id.clone(),
            messages,
            composer.title.clone(),
        );
        if let Some(object) = session.as_object_mut() {
            object.insert("model".to_string(), json!(composer.model.clone()));
            if let Some(created_at) = composer.created_at.clone() {
                object.insert("createdAt".to_string(), json!(created_at));
            }
            if let Some(updated_at) = composer.updated_at.clone() {
                object.insert("updatedAt".to_string(), json!(updated_at));
            }
        }
        sessions.push(session);
    }
    sessions
}

#[derive(Clone, Debug)]
struct CursorComposerMeta {
    id: String,
    title: Option<String>,
    model: String,
    created_at: Option<String>,
    updated_at: Option<String>,
    bubble_ids: Vec<String>,
}

fn cursor_composer_rows(connection: &Connection) -> Vec<CursorComposerMeta> {
    let Ok(mut statement) =
        connection.prepare("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'")
    else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, sqlite_value_text(row.get_ref(1)?)))
    }) else {
        return Vec::new();
    };

    let mut composers = Vec::new();
    for row in rows.flatten() {
        let (key, value) = row;
        let Ok(json) = serde_json::from_str::<Value>(&value) else {
            continue;
        };
        let id = json
            .get("composerId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                key.strip_prefix("composerData:")
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
            });
        let Some(id) = id else {
            continue;
        };
        let model = cursor_composer_model_from_config(&json);
        let title = json
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let bubble_ids = json
            .get("fullConversationHeadersOnly")
            .and_then(Value::as_array)
            .map(|headers| {
                headers
                    .iter()
                    .filter_map(|header| {
                        header
                            .get("bubbleId")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        composers.push(CursorComposerMeta {
            id,
            title,
            model,
            created_at: epoch_value_to_rfc3339(json.get("createdAt").unwrap_or(&Value::Null)),
            updated_at: epoch_value_to_rfc3339(
                json.get("lastUpdatedAt")
                    .or_else(|| json.get("updatedAt"))
                    .unwrap_or(&Value::Null),
            ),
            bubble_ids,
        });
    }
    composers
}

fn cursor_bubble_ids_for_composer(connection: &Connection, composer_id: &str) -> Vec<String> {
    let pattern = format!("bubbleId:{}:%", composer_id);
    let Ok(mut statement) = connection.prepare("SELECT key FROM cursorDiskKV WHERE key LIKE ?1")
    else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([pattern], |row| row.get::<_, String>(0)) else {
        return Vec::new();
    };
    let prefix = format!("bubbleId:{}:", composer_id);
    rows.flatten()
        .filter_map(|key| {
            key.strip_prefix(&prefix)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .collect()
}

fn cursor_disk_kv_json(connection: &Connection, key: &str) -> Option<Value> {
    let value: String = connection
        .query_row(
            "SELECT value FROM cursorDiskKV WHERE key = ?1 LIMIT 1",
            [key],
            |row| Ok(sqlite_value_text(row.get_ref(0)?)),
        )
        .ok()?;
    serde_json::from_str(&value).ok()
}

fn cursor_message_from_bubble(
    bubble: &Value,
    fallback_model: &str,
    path: &Path,
    index: usize,
) -> Option<Value> {
    let role = cursor_bubble_role(bubble)?;
    let created_at = epoch_value_to_rfc3339(bubble.get("createdAt").unwrap_or(&Value::Null))
        .or_else(|| extract_timestamp(bubble));
    let text = extract_text(bubble).unwrap_or_default();
    let model = cursor_bubble_model(bubble).unwrap_or_else(|| fallback_model.to_string());
    let usage = cursor_bubble_usage(bubble, &model);
    let has_usage = usage
        .as_ref()
        .and_then(|value| value.get("totalTokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0)
        > 0;
    if text.trim().is_empty() && !has_usage {
        return None;
    }
    let mut message = json!({
        "id": native_history_message_id(HistoryAdapter::Cursor, path, index, 0),
        "role": role,
        "text": text,
        "createdAt": created_at.unwrap_or_else(native_message_timestamp),
        "sourcePath": display_path(path),
        "model": model,
    });
    if let Some(usage) = usage
        && let Some(object) = message.as_object_mut()
    {
        object.insert("usage".to_string(), usage);
        object.insert("usageScope".to_string(), json!("request-response"));
    }
    Some(message)
}

fn cursor_bubble_role(bubble: &Value) -> Option<&'static str> {
    match bubble.get("type").and_then(Value::as_i64) {
        Some(1) => Some("user"),
        Some(2) | Some(0) => Some("agent"),
        _ => {
            let role = extract_role(bubble);
            if role == "user" {
                Some("user")
            } else if role == "agent" || role == "assistant" {
                Some("agent")
            } else {
                None
            }
        }
    }
}

fn cursor_composer_model_from_config(json: &Value) -> String {
    // Cursor stores the picker selection in selectedModels[].modelId. modelName
    // may be a Composer/Auto product label while the billed model lives here.
    if let Some(selected) = json
        .pointer("/modelConfig/selectedModels")
        .and_then(Value::as_array)
    {
        for item in selected {
            let Some(model_id) = item
                .get("modelId")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            if !model_id.eq_ignore_ascii_case("default") {
                return normalize_cursor_model_name(model_id);
            }
        }
    }
    normalize_cursor_model_name(
        json.pointer("/modelConfig/modelName")
            .and_then(Value::as_str)
            .or_else(|| json.get("modelName").and_then(Value::as_str))
            .or_else(|| json.get("model").and_then(Value::as_str))
            .unwrap_or("default"),
    )
}

fn cursor_bubble_model(bubble: &Value) -> Option<String> {
    // Treat "default" as unresolved so the composer selected model can win.
    bubble
        .pointer("/modelInfo/modelName")
        .and_then(Value::as_str)
        .or_else(|| bubble.get("modelName").and_then(Value::as_str))
        .or_else(|| bubble.get("model").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("default"))
        .map(normalize_cursor_model_name)
}

fn cursor_bubble_usage(bubble: &Value, model: &str) -> Option<Value> {
    let token_count = bubble.get("tokenCount")?;
    let mut usage = UsageFields::default();
    collect_token_usage(token_count, 0, &mut usage);
    let mut json = usage.to_json()?;
    if let Some(object) = json.as_object_mut() {
        if object
            .get("totalTokens")
            .and_then(Value::as_u64)
            .unwrap_or(0)
            == 0
        {
            return None;
        }
        if !model.trim().is_empty() {
            object.insert("model".to_string(), json!(model));
        }
    }
    Some(json)
}

fn normalize_cursor_model_name(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("default") {
        "cursor-auto".to_string()
    } else {
        trimmed.to_string()
    }
}

fn parse_openagent_sqlite_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    connection: &mut Connection,
) -> Vec<Value> {
    let transaction = match connection.transaction_with_behavior(TransactionBehavior::Deferred) {
        Ok(transaction) => transaction,
        Err(_) => return Vec::new(),
    };
    if !sqlite_table_exists(&transaction, "session")
        || !sqlite_table_exists(&transaction, "message")
        || !sqlite_table_exists(&transaction, "part")
    {
        return Vec::new();
    }

    let sessions = openagent_session_rows(&transaction)
        .into_iter()
        .filter_map(|meta| {
            let messages = openagent_messages_for_session(adapter, path, &transaction, &meta.id);
            if messages.is_empty() {
                return None;
            }
            let mut session = session_from_messages_with_title(
                adapter,
                path,
                metadata,
                source_kind,
                meta.id.clone(),
                messages,
                meta.title.clone(),
            );
            if let Some(object) = session.as_object_mut() {
                if let Some(created_at) = meta.created_at {
                    object.insert("createdAt".to_string(), json!(created_at));
                }
                if let Some(updated_at) = meta.updated_at {
                    object.insert("updatedAt".to_string(), json!(updated_at));
                }
                if let Some(directory) = meta.directory.filter(|value| !value.trim().is_empty()) {
                    object.insert("workingDirectory".to_string(), json!(directory));
                }
                if let Some(path) = meta.path.filter(|value| !value.trim().is_empty()) {
                    object.insert("projectPath".to_string(), json!(path));
                }
                if let Some(agent) = meta.agent.filter(|value| !value.trim().is_empty()) {
                    object.insert("nativeAgent".to_string(), json!(agent));
                }
                if let Some(model) = meta.model.filter(|value| !value.trim().is_empty()) {
                    object.insert("model".to_string(), json!(model));
                }
                if let Some(usage) = meta.usage {
                    object.insert("usage".to_string(), usage);
                }
            }
            Some(session)
        })
        .collect();
    if transaction.commit().is_err() {
        return Vec::new();
    }
    sessions
}

fn sqlite_table_exists(connection: &Connection, table: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok()
}

fn openagent_session_rows(connection: &Connection) -> Vec<OpenAgentSessionMeta> {
    let mut statement = match connection.prepare(
        "SELECT id, title, directory, path, agent, model, time_created, time_updated, \
         tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write \
         FROM session ORDER BY time_updated DESC, id ASC",
    ) {
        Ok(statement) => statement,
        Err(_) => return Vec::new(),
    };
    let rows = match statement.query_map([], |row| {
        let tokens_input = row.get::<_, Option<i64>>(8)?;
        let tokens_output = row.get::<_, Option<i64>>(9)?;
        let tokens_reasoning = row.get::<_, Option<i64>>(10)?;
        let tokens_cache_read = row.get::<_, Option<i64>>(11)?;
        let tokens_cache_write = row.get::<_, Option<i64>>(12)?;
        Ok(OpenAgentSessionMeta {
            id: row.get::<_, String>(0)?,
            title: row.get::<_, Option<String>>(1)?,
            directory: row.get::<_, Option<String>>(2)?,
            path: row.get::<_, Option<String>>(3)?,
            agent: row.get::<_, Option<String>>(4)?,
            model: row.get::<_, Option<String>>(5)?,
            created_at: row
                .get::<_, Option<i64>>(6)?
                .and_then(epoch_number_to_rfc3339),
            updated_at: row
                .get::<_, Option<i64>>(7)?
                .and_then(epoch_number_to_rfc3339),
            usage: openagent_usage_from_columns(
                tokens_input,
                tokens_output,
                tokens_reasoning,
                tokens_cache_read,
                tokens_cache_write,
            ),
        })
    }) {
        Ok(rows) => rows,
        Err(_) => return Vec::new(),
    };
    rows.filter_map(Result::ok).collect()
}

fn openagent_messages_for_session(
    adapter: HistoryAdapter,
    path: &Path,
    connection: &Connection,
    session_id: &str,
) -> Vec<Value> {
    let mut parts_by_message = openagent_parts_by_message(connection, session_id);
    let mut statement = match connection.prepare(
        "SELECT id, time_created, time_updated, data FROM message \
         WHERE session_id=?1 ORDER BY time_created ASC, id ASC",
    ) {
        Ok(statement) => statement,
        Err(_) => return Vec::new(),
    };
    let rows = match statement.query_map([session_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, String>(3)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(_) => return Vec::new(),
    };

    let mut messages = Vec::<Value>::new();
    for (index, (message_id, created_at, updated_at, data)) in
        rows.filter_map(Result::ok).enumerate()
    {
        let data_value = serde_json::from_str::<Value>(&data).unwrap_or(Value::Null);
        let role = extract_role(&data_value);
        let parts = parts_by_message.remove(&message_id).unwrap_or_default();
        let created = openagent_json_time(&data_value, "created")
            .or_else(|| created_at.and_then(epoch_number_to_rfc3339))
            .or_else(|| openagent_json_time(&data_value, "completed"))
            .or_else(|| updated_at.and_then(epoch_number_to_rfc3339))
            .unwrap_or_else(native_message_timestamp);
        let mut envelope = data_value.clone();
        if !envelope.is_object() {
            envelope = json!({});
        }
        if let Some(object) = envelope.as_object_mut() {
            object
                .entry("role".to_string())
                .or_insert_with(|| json!(role));
            object.insert("createdAt".to_string(), json!(created));
            if !parts.is_empty() {
                object.insert("content".to_string(), Value::Array(parts));
            }
        }
        let mut expanded = messages_from_json(adapter, path, index, &envelope);
        let expanded_len = expanded.len();
        for (block_index, mut message) in expanded.drain(..).enumerate() {
            if let Some(object) = message.as_object_mut() {
                object.insert(
                    "id".to_string(),
                    json!(if expanded_len == 1 {
                        format!("{message_id}:{index}")
                    } else {
                        format!("{message_id}:{index}:{block_index}")
                    }),
                );
                object.insert("sourceMessageId".to_string(), json!(message_id.clone()));
            }
            messages.push(message);
        }
    }
    messages
}

fn openagent_parts_by_message(
    connection: &Connection,
    session_id: &str,
) -> HashMap<String, Vec<Value>> {
    let mut statement = match connection.prepare(
        "SELECT message_id, data FROM part WHERE session_id=?1 ORDER BY time_created ASC, id ASC",
    ) {
        Ok(statement) => statement,
        Err(_) => return HashMap::new(),
    };
    let rows = match statement.query_map([session_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }) {
        Ok(rows) => rows,
        Err(_) => return HashMap::new(),
    };
    let mut out = HashMap::<String, Vec<Value>>::new();
    for (message_id, data) in rows.filter_map(Result::ok) {
        let value = serde_json::from_str::<Value>(&data).unwrap_or_else(|_| json!(data));
        out.entry(message_id).or_default().push(value);
    }
    out
}

fn openagent_json_time(value: &Value, key: &str) -> Option<String> {
    value
        .get("time")
        .and_then(|time| time.get(key))
        .and_then(epoch_value_to_rfc3339)
}

fn openagent_usage_from_columns(
    input: Option<i64>,
    output: Option<i64>,
    reasoning: Option<i64>,
    cache_read: Option<i64>,
    cache_write: Option<i64>,
) -> Option<Value> {
    let cached_input_tokens = cache_read.unwrap_or(0).max(0);
    let prompt_tokens = [input, cache_read, cache_write]
        .into_iter()
        .flatten()
        .filter(|value| *value > 0)
        .sum::<i64>();
    let completion_tokens = [output, reasoning]
        .into_iter()
        .flatten()
        .filter(|value| *value > 0)
        .sum::<i64>();
    let total_tokens = prompt_tokens + completion_tokens;
    if total_tokens <= 0 {
        return None;
    }
    Some(json!({
        "promptTokens": prompt_tokens,
        "cachedInputTokens": cached_input_tokens,
        "completionTokens": completion_tokens,
        "totalTokens": total_tokens,
        "source": "openagent-sqlite"
    }))
}

fn collect_explicit_json_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    metadata: &fs::Metadata,
    source_kind: &str,
    value: &Value,
) -> Vec<Value> {
    let Some(object) = value.as_object() else {
        return Vec::new();
    };
    let mut sessions = Vec::<Value>::new();
    for key in ["sessions", "conversations", "chats", "chatSessions"] {
        let Some(Value::Array(items)) = object.get(key) else {
            continue;
        };
        for (index, item) in items.iter().enumerate() {
            let mut messages = Vec::<Value>::new();
            collect_messages_from_value(adapter, path, item, &mut messages);
            if messages.is_empty() {
                continue;
            }
            sessions.push(session_from_messages_with_title(
                adapter,
                path,
                metadata,
                source_kind,
                extract_native_session_id(item).unwrap_or_else(|| format!("{}-{}", key, index)),
                messages,
                extract_conversation_title(item),
            ));
        }
    }
    sessions
}

fn push_grouped_message(
    groups: &mut Vec<(String, Vec<Value>)>,
    session_id: String,
    message: Value,
) {
    if let Some((_, messages)) = groups.iter_mut().find(|(id, _)| *id == session_id) {
        messages.push(message);
    } else {
        groups.push((session_id, vec![message]));
    }
}

fn collect_messages_from_value(
    adapter: HistoryAdapter,
    path: &Path,
    value: &Value,
    out: &mut Vec<Value>,
) {
    match value {
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                if value_is_conversation_container(item) {
                    collect_messages_from_value(adapter, path, item, out);
                } else {
                    let messages = messages_from_json(adapter, path, index, item);
                    if messages.is_empty() {
                        collect_messages_from_value(adapter, path, item, out);
                    } else {
                        out.extend(messages);
                    }
                }
            }
        }
        Value::Object(object) => {
            let before = out.len();
            for key in [
                "messages",
                "conversation",
                "conversations",
                "transcript",
                "turns",
                "items",
                "entries",
                "sessions",
                "chats",
                "chatSessions",
            ] {
                if let Some(child) = object.get(key) {
                    collect_messages_from_value(adapter, path, child, out);
                }
            }
            if out.len() == before {
                let messages = messages_from_json(adapter, path, 0, value);
                if !messages.is_empty() {
                    out.extend(messages);
                }
            }
        }
        _ => {}
    }
}

fn value_is_conversation_container(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let has_container = [
        "messages",
        "conversation",
        "conversations",
        "transcript",
        "turns",
        "entries",
        "sessions",
        "chats",
        "chatSessions",
    ]
    .iter()
    .any(|key| object.contains_key(*key));
    let has_direct_message_text = [
        "text", "content", "prompt", "response", "answer", "summary", "value",
    ]
    .iter()
    .any(|key| object.contains_key(*key));
    has_container && !has_direct_message_text
}

fn messages_from_json(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    value: &Value,
) -> Vec<Value> {
    let role = extract_role(value);
    let created_at = extract_timestamp(value);
    if let Some(blocks) = direct_native_content_blocks(value) {
        let mut messages = blocks
            .iter()
            .enumerate()
            .filter_map(|(block_index, block)| {
                message_from_native_content_block(
                    adapter,
                    path,
                    index,
                    block_index,
                    &role,
                    block,
                    created_at.clone(),
                )
            })
            .collect::<Vec<_>>();
        if !messages.is_empty() {
            if let Some(usage) = extract_token_usage(value) {
                let target_index = messages.len() - 1;
                if let Some(object) = messages[target_index].as_object_mut() {
                    object.insert("usage".to_string(), usage);
                    object.insert("usageScope".to_string(), json!("request-response"));
                }
            }
            return messages;
        }
    }
    let kind = history_message_kind_from_semantic(&role);
    if kind != HistoryMessageKind::Text {
        return vec![structured_history_message(
            adapter, path, index, 0, kind, &role, value, created_at,
        )];
    }
    let Some(text) = extract_text(value) else {
        return Vec::new();
    };
    if let Some(message) =
        delegated_subagent_prompt_message(adapter, path, index, &role, &text, created_at.clone())
    {
        return vec![message];
    }
    let Some(mut message) =
        plain_history_message(adapter, path, index, 0, &role, &text, created_at)
    else {
        return Vec::new();
    };
    if let Some(usage) = extract_token_usage(value)
        && let Some(object) = message.as_object_mut()
    {
        object.insert("usage".to_string(), usage);
        object.insert("usageScope".to_string(), json!("request-response"));
    }
    vec![message]
}

fn direct_native_content_blocks(value: &Value) -> Option<&Vec<Value>> {
    value
        .get("message")
        .and_then(|message| message.get("content"))
        .or_else(|| value.get("content"))
        .and_then(Value::as_array)
}

fn message_from_native_content_block(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    block_index: usize,
    outer_role: &str,
    block: &Value,
    created_at: Option<String>,
) -> Option<Value> {
    let semantic = native_content_semantic(block);
    let kind = history_message_kind_from_semantic(&semantic);
    if kind != HistoryMessageKind::Text {
        return Some(structured_history_message(
            adapter,
            path,
            index,
            block_index,
            kind,
            &semantic,
            block,
            created_at,
        ));
    }
    let text = extract_text(block)?;
    if let Some(message) = delegated_subagent_prompt_message(
        adapter,
        path,
        index,
        outer_role,
        &text,
        created_at.clone(),
    ) {
        return Some(message);
    }
    plain_history_message(
        adapter,
        path,
        index,
        block_index,
        outer_role,
        &text,
        created_at,
    )
}

fn native_content_semantic(value: &Value) -> String {
    value
        .as_object()
        .and_then(|object| {
            ["type", "kind", "role", "eventType", "event_type"]
                .iter()
                .find_map(|key| object.get(*key).and_then(Value::as_str))
        })
        .unwrap_or_default()
        .to_string()
}

fn plain_history_message(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    block_index: usize,
    role: &str,
    text: &str,
    created_at: Option<String>,
) -> Option<Value> {
    let text = clean_native_message_text(adapter, role, text)?;
    let mut message = json!({
        "id": native_history_message_id(adapter, path, index, block_index),
        "role": role,
        "text": text,
        "createdAt": created_at.unwrap_or_else(native_message_timestamp),
        "sourcePath": display_path(path)
    });
    crate::domain::conversation_semantic::annotate_message_layer(
        &mut message,
        crate::domain::conversation_semantic::SemanticLayer::Thread,
    );
    Some(message)
}

fn structured_history_message(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    block_index: usize,
    kind: HistoryMessageKind,
    semantic: &str,
    value: &Value,
    created_at: Option<String>,
) -> Value {
    let normalized_semantic = normalize_history_message_semantic(semantic);
    let (role, card_type, default_title, subtitle, fallback, collapsed) = match kind {
        HistoryMessageKind::ToolCall => (
            "tool_call",
            "tool-call",
            "Tool call",
            "Native agent activity",
            "Invocation details are hidden.",
            true,
        ),
        HistoryMessageKind::ToolResult => (
            "tool_result",
            "tool-result",
            "Tool result",
            "Native agent result",
            "The native tool result was recorded.",
            true,
        ),
        HistoryMessageKind::Reasoning => (
            "reasoning",
            "reasoning",
            "Reasoning",
            "Sensitive details hidden",
            "Reasoning details are redacted.",
            true,
        ),
        HistoryMessageKind::Metadata => (
            "metadata",
            "metadata",
            "Metadata",
            "Sensitive details hidden",
            "Sensitive native metadata is hidden.",
            true,
        ),
        HistoryMessageKind::Error => (
            "error",
            "error",
            "Error",
            "Native agent error",
            "The native agent reported an error.",
            false,
        ),
        _ => (
            "event",
            "event",
            "Native event",
            "Native agent event",
            "Native event details are hidden.",
            true,
        ),
    };
    let title = structured_event_title(value, &normalized_semantic, default_title);
    let provider_summary = if kind == HistoryMessageKind::Reasoning {
        structured_reasoning_summary(value).and_then(|text| sanitize_structured_event_text(&text))
    } else {
        None
    };
    let provider_summary_visible = provider_summary.is_some();
    let text = provider_summary.unwrap_or_else(|| structured_event_text(kind, value, fallback));
    let subtitle = if provider_summary_visible {
        "Reasoning summary"
    } else {
        subtitle
    };
    let mut message = json!({
        "id": native_history_message_id(adapter, path, index, block_index),
        "role": role,
        "text": text,
        "createdAt": created_at.unwrap_or_else(native_message_timestamp),
        "cardType": card_type,
        "cardTitle": title,
        "cardSubtitle": subtitle,
        "collapsed": collapsed,
        "sourcePath": display_path(path),
        "sourceItemType": normalized_semantic
    });
    if provider_summary_visible && let Some(object) = message.as_object_mut() {
        object.insert("providerSummary".to_string(), json!(true));
    }
    crate::domain::conversation_semantic::annotate_message_layer(
        &mut message,
        crate::domain::conversation_semantic::SemanticLayer::Execution,
    );
    message
}

fn history_message_kind_from_semantic(value: &str) -> HistoryMessageKind {
    let semantic = normalize_history_message_semantic(value);
    if semantic.is_empty()
        || matches!(
            semantic.as_str(),
            "text"
                | "input-text"
                | "output-text"
                | "markdown"
                | "message"
                | "summary-text"
                | "user"
                | "human"
                | "assistant"
                | "agent"
                | "model"
                | "ai"
                | "planner-response"
                | "generic"
        )
        || semantic.ends_with("-user-message")
        || semantic.ends_with("-assistant-message")
        || matches!(semantic.as_str(), "user-message" | "assistant-message")
    {
        return HistoryMessageKind::Text;
    }
    if semantic.contains("reasoning")
        || semantic.contains("analysis")
        || semantic.contains("thinking")
    {
        return HistoryMessageKind::Reasoning;
    }
    if semantic.contains("error")
        || semantic.contains("failure")
        || semantic.contains("failed")
        || semantic.contains("exception")
    {
        return HistoryMessageKind::Error;
    }
    if semantic == "metadata"
        || matches!(
            semantic.as_str(),
            "image" | "image-url" | "document" | "attachment" | "input-json-delta"
        )
    {
        return HistoryMessageKind::Metadata;
    }
    if matches!(
        semantic.as_str(),
        "tool-result"
            | "tool-output"
            | "function-result"
            | "function-output"
            | "function-call-output"
    ) || ((semantic.contains("tool") || semantic.contains("function"))
        && [
            "result",
            "output",
            "complete",
            "completed",
            "response",
            "end",
        ]
        .iter()
        .any(|marker| semantic.contains(marker)))
    {
        return HistoryMessageKind::ToolResult;
    }
    if matches!(
        semantic.as_str(),
        "tool"
            | "tool-call"
            | "tool-use"
            | "function"
            | "function-call"
            | "run-command"
            | "view-file"
            | "list-directory"
            | "grep-search"
            | "read-url-content"
            | "generate-image"
            | "code-action"
    ) || semantic.contains("tool")
        || semantic.contains("function")
    {
        return HistoryMessageKind::ToolCall;
    }
    HistoryMessageKind::Event
}

fn normalize_history_message_semantic(value: &str) -> String {
    let mut normalized = String::new();
    let mut separator = false;
    for character in value.trim().chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !normalized.is_empty() {
                normalized.push('-');
            }
            separator = false;
            normalized.push(character.to_ascii_lowercase());
        } else {
            separator = true;
        }
    }
    normalized
}

fn structured_event_title(value: &Value, semantic: &str, fallback: &str) -> String {
    let name = [
        "name",
        "toolName",
        "tool_name",
        "functionName",
        "function_name",
    ]
    .iter()
    .find_map(|key| value.get(*key).and_then(Value::as_str))
    .and_then(sanitize_structured_label);
    if let Some(name) = name {
        return name;
    }
    if matches!(
        semantic,
        "run-command"
            | "view-file"
            | "list-directory"
            | "grep-search"
            | "read-url-content"
            | "generate-image"
            | "code-action"
    ) {
        return humanize_history_semantic(semantic);
    }
    fallback.to_string()
}

fn humanize_history_semantic(value: &str) -> String {
    let mut words = value.split('-').filter(|word| !word.is_empty());
    let Some(first) = words.next() else {
        return "Native event".to_string();
    };
    let mut label = first.to_string();
    if let Some(first_character) = label.get_mut(0..1) {
        first_character.make_ascii_uppercase();
    }
    for word in words {
        label.push(' ');
        label.push_str(word);
    }
    label
}

fn structured_event_text(kind: HistoryMessageKind, value: &Value, fallback: &str) -> String {
    if matches!(
        kind,
        HistoryMessageKind::Reasoning | HistoryMessageKind::Metadata | HistoryMessageKind::ToolCall
    ) {
        return fallback.to_string();
    }
    let candidate = structured_event_detail_candidate(value);
    candidate
        .and_then(|text| sanitize_structured_event_text(&text))
        .unwrap_or_else(|| fallback.to_string())
}

/// Only provider-owned summary fields are eligible for display. A generic
/// reasoning/thinking text field can contain chain-of-thought and therefore
/// remains redacted even when it looks human-readable.
fn structured_reasoning_summary(value: &Value) -> Option<String> {
    for key in ["summary", "reasoningSummary", "reasoning_summary"] {
        let Some(candidate) = value.get(key) else {
            continue;
        };
        if let Some(summary) = structured_reasoning_summary_value(candidate, 0) {
            return Some(summary);
        }
    }
    None
}

fn structured_reasoning_summary_value(value: &Value, depth: usize) -> Option<String> {
    if depth > 3 {
        return None;
    }
    match value {
        Value::String(text) => (!text.trim().is_empty()).then(|| text.trim().to_string()),
        Value::Array(items) => {
            let summaries = items
                .iter()
                .filter_map(|item| structured_reasoning_summary_value(item, depth + 1))
                .collect::<Vec<_>>();
            (!summaries.is_empty()).then(|| summaries.join("\n"))
        }
        Value::Object(object) => {
            if let Some(kind) = object
                .get("type")
                .or_else(|| object.get("kind"))
                .and_then(Value::as_str)
            {
                let normalized = normalize_history_message_semantic(kind);
                if !matches!(
                    normalized.as_str(),
                    "summary" | "summary-text" | "reasoning-summary" | "text"
                ) {
                    return None;
                }
            }
            ["text", "content", "summary"]
                .iter()
                .find_map(|key| object.get(*key))
                .and_then(|candidate| structured_reasoning_summary_value(candidate, depth + 1))
        }
        _ => None,
    }
}

fn structured_event_detail_candidate(value: &Value) -> Option<String> {
    for key in [
        "error", "reason", "message", "summary", "text", "output", "result", "content",
    ] {
        let Some(candidate) = value.get(key) else {
            continue;
        };
        if let Some(text) = candidate.as_str() {
            if !text.trim().is_empty() {
                return Some(text.to_string());
            }
        }
        if key == "error" {
            if let Some(text) = candidate.get("message").and_then(Value::as_str) {
                if !text.trim().is_empty() {
                    return Some(text.to_string());
                }
            }
        }
    }
    None
}

fn sanitize_structured_label(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > 96
        || trimmed
            .chars()
            .any(|character| matches!(character, '\n' | '\r' | '/' | '\\' | '{' | '}' | '[' | ']'))
        || structured_secret_assignment_regex().is_match(trimmed)
        || structured_opaque_value_regex().is_match(trimmed)
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn sanitize_structured_event_text(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || looks_like_raw_structured_payload(trimmed) {
        return None;
    }
    let redacted = structured_bearer_regex().replace_all(trimmed, "Bearer [redacted]");
    let redacted = structured_secret_assignment_regex().replace_all(&redacted, "$1: [redacted]");
    let redacted = structured_local_path_regex().replace_all(&redacted, "[local path hidden]");
    let redacted = structured_relative_path_regex().replace_all(&redacted, "$1[local path hidden]");
    let redacted = structured_opaque_value_regex().replace_all(&redacted, "[opaque value hidden]");
    let redacted = redacted.trim();
    if redacted.is_empty() {
        return None;
    }
    let mut text = redacted
        .chars()
        .take(MAX_STRUCTURED_EVENT_TEXT_CHARS)
        .collect::<String>();
    if redacted.chars().count() > MAX_STRUCTURED_EVENT_TEXT_CHARS {
        text.push_str("\n…");
    }
    Some(text)
}

fn looks_like_raw_structured_payload(value: &str) -> bool {
    let trimmed = value.trim();
    let candidate = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```JSON"))
        .map(|text| {
            text.trim()
                .strip_suffix("```")
                .unwrap_or(text.trim())
                .trim()
        })
        .unwrap_or(trimmed);
    if candidate.contains("{\"") || candidate.contains("[{") {
        return true;
    }
    if !((candidate.starts_with('{') && candidate.ends_with('}'))
        || (candidate.starts_with('[') && candidate.ends_with(']')))
    {
        return false;
    }
    serde_json::from_str::<Value>(candidate)
        .map(|value| value.is_object() || value.is_array())
        .unwrap_or(true)
}

fn native_history_message_id(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    block_index: usize,
) -> String {
    let id = message_id(adapter.id(), path, index);
    if block_index == 0 {
        id
    } else {
        format!("{id}:{block_index}")
    }
}

fn native_message_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn structured_bearer_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?i)\bbearer\s+[a-z0-9._~+\-/]+=*").expect("valid bearer regex")
    })
}

fn structured_secret_assignment_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|secret|cookie|credential)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("valid secret assignment regex")
    })
}

fn structured_local_path_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r#"(?i)(?:file://)?/(?:users|home|private|tmp|workspace|workspaces|volumes|var/folders|opt)/[^\s\"'<>]*|[a-z]:\\[^\s\"'<>]*|~[/\\][^\s\"'<>]*"#,
        )
        .expect("valid local path regex")
    })
}

fn structured_relative_path_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r#"(?i)(^|[\s("'=])((?:\.{1,2}[/\\])?[a-z0-9._-]+(?:[/\\][a-z0-9._-]+)+)"#)
            .expect("valid relative local path regex")
    })
}

fn structured_opaque_value_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"\b[a-zA-Z0-9_-]{40,}\b").expect("valid opaque value regex"))
}

fn delegated_subagent_prompt_message(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    role: &str,
    text: &str,
    created_at: Option<String>,
) -> Option<Value> {
    if !matches!(role, "user" | "human") {
        return None;
    }
    let prompt = extract_user_authored_text(text);
    if !looks_like_delegated_agent_prompt(&prompt) {
        return None;
    }
    let title = delegated_subagent_prompt_title(&prompt)
        .filter(|title| !title.trim().is_empty())
        .unwrap_or_else(|| "Subagent task".to_string());
    Some(json!({
        "id": message_id(adapter.id(), path, index),
        "role": "subagent_prompt",
        "text": title.clone(),
        "createdAt": created_at.unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        }),
        "sourcePath": display_path(path),
        "subagentPrompt": true,
        "subagentTitle": title
    }))
}

fn extract_token_usage(value: &Value) -> Option<Value> {
    let mut usage = UsageFields::default();
    collect_token_usage(value, 0, &mut usage);
    usage.to_json()
}

#[derive(Default)]
struct UsageFields {
    prompt_tokens: u64,
    cached_input_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    explicit_fields: usize,
    normalized_additive_semantics: bool,
}

impl UsageFields {
    fn to_json(&self) -> Option<Value> {
        if self.explicit_fields == 0 {
            return None;
        }
        let mut prompt_tokens = self.prompt_tokens;
        let mut completion_tokens = self.completion_tokens;
        let field_total = prompt_tokens.saturating_add(completion_tokens);
        let total_tokens = if self.normalized_additive_semantics {
            field_total
        } else if self.total_tokens > 0 {
            self.total_tokens
        } else {
            field_total
        };
        if !self.normalized_additive_semantics && field_total != total_tokens {
            if field_total > total_tokens {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            } else if prompt_tokens > 0 {
                prompt_tokens = prompt_tokens.min(total_tokens);
                completion_tokens = total_tokens.saturating_sub(prompt_tokens);
            } else {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            }
        }
        Some(json!({
            "promptTokens": prompt_tokens,
            "cachedInputTokens": self.cached_input_tokens.min(prompt_tokens),
            "completionTokens": completion_tokens,
            "totalTokens": total_tokens,
            "source": "explicit"
        }))
    }
}

fn collect_token_usage(value: &Value, depth: usize, usage: &mut UsageFields) {
    if depth > 4 {
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    for key in [
        "usage",
        "tokenUsage",
        "token_usage",
        "tokenCount",
        "token_count",
        "responseUsage",
        "response_usage",
        "tokens",
        "message",
    ] {
        let Some(child) = object.get(key) else {
            continue;
        };
        let mut nested = UsageFields::default();
        collect_token_usage(child, depth + 1, &mut nested);
        if nested.explicit_fields > 0 {
            *usage = nested;
            return;
        }
    }
    let normalized_input_output = object.contains_key("input") && object.contains_key("output");
    usage.normalized_additive_semantics |=
        normalized_input_output && object.get("cache").and_then(Value::as_object).is_some();
    let base_prompt = token_count_field(
        object,
        &[
            "promptTokens",
            "prompt_tokens",
            "inputTokens",
            "input_tokens",
            "input",
        ],
        usage,
    );
    let cached_subset =
        token_count_field(object, &["cachedInputTokens", "cached_input_tokens"], usage);
    let cache_read = token_count_field(
        object,
        &["cacheReadInputTokens", "cache_read_input_tokens"],
        usage,
    );
    let cache_write = token_count_field(
        object,
        &[
            "cacheCreationInputTokens",
            "cache_creation_input_tokens",
            "cacheWriteInputTokens",
            "cache_write_input_tokens",
        ],
        usage,
    );
    usage.prompt_tokens = usage
        .prompt_tokens
        .saturating_add(base_prompt)
        .saturating_add(cache_read)
        .saturating_add(cache_write);
    usage.cached_input_tokens = usage
        .cached_input_tokens
        .saturating_add(cached_subset.min(base_prompt))
        .saturating_add(cache_read);
    if let Some(cache) = object.get("cache").and_then(Value::as_object) {
        let normalized_cache_read = token_count_field(cache, &["read"], usage);
        let normalized_cache_write = token_count_field(cache, &["write"], usage);
        usage.prompt_tokens = usage
            .prompt_tokens
            .saturating_add(normalized_cache_read)
            .saturating_add(normalized_cache_write);
        usage.cached_input_tokens = usage
            .cached_input_tokens
            .saturating_add(normalized_cache_read);
    }
    if normalized_input_output {
        usage.completion_tokens = usage.completion_tokens.saturating_add(token_count_field(
            object,
            &["reasoning"],
            usage,
        ));
    }
    usage.completion_tokens = usage.completion_tokens.saturating_add(token_count_field(
        object,
        &[
            "completionTokens",
            "completion_tokens",
            "outputTokens",
            "output_tokens",
            "responseTokens",
            "response_tokens",
            "output",
        ],
        usage,
    ));
    usage.total_tokens = usage.total_tokens.saturating_add(token_count_field(
        object,
        &["totalTokens", "total_tokens", "total"],
        usage,
    ));
}

fn token_count_field(
    object: &serde_json::Map<String, Value>,
    keys: &[&str],
    usage: &mut UsageFields,
) -> u64 {
    keys.iter()
        .find_map(|key| object.get(*key).and_then(token_count_value))
        .inspect(|_| usage.explicit_fields += 1)
        .unwrap_or(0)
}

fn token_count_value(value: &Value) -> Option<u64> {
    if let Some(number) = value.as_u64() {
        return Some(number);
    }
    if let Some(number) = value.as_i64().filter(|number| *number >= 0) {
        return Some(number as u64);
    }
    value
        .as_str()
        .and_then(|text| text.trim().parse::<u64>().ok())
}

fn extract_text(value: &Value) -> Option<String> {
    extract_text_at_depth(value, 0)
}

fn extract_text_at_depth(value: &Value, depth: usize) -> Option<String> {
    match value {
        Value::String(text) => extract_text_from_string(text, depth),
        Value::Array(items) => {
            let parts = items
                .iter()
                .filter_map(|item| extract_text_at_depth(item, depth + 1))
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join("\n"))
            }
        }
        Value::Object(object) => {
            if structured_content_object_is_tool_or_metadata(object) {
                return None;
            }
            if structured_content_object_is_text(object) {
                return object
                    .get("text")
                    .or_else(|| object.get("content"))
                    .and_then(|value| extract_text_at_depth(value, depth + 1));
            }
            for key in [
                "text", "content", "message", "messages", "prompt", "response", "answer",
                "summary", "value", "parts", "items", "turns",
            ] {
                if let Some(text) = object
                    .get(key)
                    .and_then(|value| extract_text_at_depth(value, depth + 1))
                {
                    if !text.trim().is_empty() {
                        return Some(text);
                    }
                }
            }
            None
        }
        _ => None,
    }
}

fn structured_content_object_is_tool_or_metadata(object: &serde_json::Map<String, Value>) -> bool {
    let kind = object
        .get("type")
        .or_else(|| object.get("kind"))
        .or_else(|| object.get("role"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        kind.as_str(),
        "tool_result"
            | "tool-use"
            | "tool_use"
            | "tool"
            | "function_call"
            | "function_call_output"
            | "input_json_delta"
            | "thinking"
            | "redacted_thinking"
            | "image"
            | "image_url"
            | "document"
            | "attachment"
            | "metadata"
            | "system"
    )
}

fn structured_content_object_is_text(object: &serde_json::Map<String, Value>) -> bool {
    let kind = object
        .get("type")
        .or_else(|| object.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        kind.as_str(),
        "text" | "input_text" | "output_text" | "markdown"
    )
}

fn extract_text_from_string(text: &str, depth: usize) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty()
        || (generated_control_text(trimmed)
            && !looks_like_delegated_agent_prompt(trimmed)
            && !antigravity_user_request_regex().is_match(trimmed))
    {
        return None;
    }
    if depth < 4 {
        if let Some(value) = parse_embedded_json_text(trimmed) {
            if value
                .as_object()
                .map(structured_content_object_is_tool_or_metadata)
                .unwrap_or(false)
            {
                return None;
            }
            if let Some(decoded) = extract_text_at_depth(&value, depth + 1) {
                let decoded = decoded.trim().to_string();
                if !decoded.is_empty()
                    && (!generated_control_text(&decoded)
                        || looks_like_delegated_agent_prompt(&decoded)
                        || antigravity_user_request_regex().is_match(&decoded))
                {
                    return Some(decoded);
                }
            }
        }
    }
    Some(text.to_string())
}

fn clean_native_message_text(adapter: HistoryAdapter, role: &str, text: &str) -> Option<String> {
    let visible = if matches!(adapter, HistoryAdapter::Antigravity) {
        clean_antigravity_message_text(role, text)?
    } else if matches!(role, "user" | "human") {
        extract_user_authored_text(text)
    } else {
        strip_generated_context_blocks(text)
    };
    let trimmed = visible.trim();
    if trimmed.is_empty()
        || generated_control_text(trimmed)
        || antigravity_system_boilerplate_text(trimmed)
        || background_context_prompt_text(trimmed)
    {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn clean_antigravity_message_text(role: &str, text: &str) -> Option<String> {
    let normalized_role = role.trim().to_ascii_lowercase();
    if !antigravity_message_role_is_visible(&normalized_role) {
        return None;
    }
    let visible = if matches!(normalized_role.as_str(), "user" | "human") {
        extract_antigravity_user_request(text)
    } else {
        strip_antigravity_system_messages(text)
    };
    let generic = if matches!(normalized_role.as_str(), "user" | "human") {
        extract_user_authored_text(&visible)
    } else {
        strip_generated_context_blocks(&visible)
    };
    Some(strip_antigravity_artifact_noise(
        &strip_antigravity_protocol_tags(&generic),
    ))
}

fn antigravity_message_role_is_visible(role: &str) -> bool {
    matches!(
        role,
        "user" | "human" | "planner_response" | "agent" | "assistant" | "generic"
    )
}

fn extract_antigravity_user_request(text: &str) -> String {
    let cleaned = strip_antigravity_system_messages(text);
    let requests = antigravity_user_request_regex()
        .captures_iter(&cleaned)
        .filter_map(|capture| capture.get(1).map(|match_| match_.as_str()))
        .map(strip_antigravity_protocol_tags)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    if requests.is_empty() {
        strip_antigravity_protocol_tags(&cleaned)
    } else {
        requests.join("\n\n")
    }
}

fn strip_antigravity_system_messages(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let without_blocks = antigravity_system_block_regex()
        .replace_all(&normalized, "\n")
        .to_string();
    let without_paragraphs = without_blocks
        .split("\n\n")
        .filter(|paragraph| !antigravity_system_boilerplate_text(paragraph))
        .collect::<Vec<_>>()
        .join("\n\n");
    let without_lines = without_paragraphs
        .lines()
        .filter(|line| !antigravity_system_boilerplate_text(line))
        .collect::<Vec<_>>()
        .join("\n");
    strip_antigravity_protocol_tags(&without_lines)
}

fn strip_antigravity_protocol_tags(text: &str) -> String {
    antigravity_protocol_tag_regex()
        .replace_all(text, "")
        .trim()
        .to_string()
}

fn strip_antigravity_artifact_noise(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines = normalized.lines().collect::<Vec<_>>();
    if looks_like_antigravity_artifact_dump(&lines) {
        return String::new();
    }
    lines
        .into_iter()
        .filter(|line| !antigravity_internal_event_line(line))
        .map(strip_antigravity_line_gutter)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

fn looks_like_antigravity_artifact_dump(lines: &[&str]) -> bool {
    let non_blank = lines.iter().filter(|line| !line.trim().is_empty()).count();
    if non_blank < 6 {
        return false;
    }
    let gutter_lines = lines
        .iter()
        .filter(|line| antigravity_line_gutter_regex().is_match(line))
        .count();
    gutter_lines >= 4 && gutter_lines * 100 / non_blank >= 35
}

fn strip_antigravity_line_gutter(line: &str) -> String {
    if antigravity_ordered_list_line_regex().is_match(line) {
        return line.trim_end().to_string();
    }
    if let Some(capture) = antigravity_line_gutter_regex().captures(line) {
        let indent = capture.get(1).map(|value| value.as_str()).unwrap_or("");
        let content = capture.get(2).map(|value| value.as_str()).unwrap_or("");
        format!("{indent}{content}").trim_end().to_string()
    } else {
        line.trim_end().to_string()
    }
}

fn antigravity_internal_event_line(line: &str) -> bool {
    matches!(
        line.trim().to_ascii_lowercase().as_str(),
        "conversation_history"
            | "user_input"
            | "planner_response"
            | "list_directory"
            | "view_file"
            | "grep_search"
            | "run_command"
            | "code_action"
            | "generate_image"
            | "read_url_content"
    )
}

fn antigravity_user_request_regex() -> &'static Regex {
    static USER_REQUEST_REGEX: OnceLock<Regex> = OnceLock::new();
    USER_REQUEST_REGEX.get_or_init(|| {
        Regex::new(r"(?is)<\s*USER[_-]?REQUEST\b[^>]*>(.*?)<\s*/\s*USER[_-]?REQUEST\s*>")
            .expect("valid Antigravity user request regex")
    })
}

fn antigravity_system_block_regex() -> &'static Regex {
    static SYSTEM_BLOCK_REGEX: OnceLock<Regex> = OnceLock::new();
    SYSTEM_BLOCK_REGEX.get_or_init(|| {
        Regex::new(r"(?is)<\s*SYSTEM[_-]?MESSAGE\b[^>]*>.*?<\s*/\s*SYSTEM[_-]?MESSAGE\s*>")
            .expect("valid Antigravity system block regex")
    })
}

fn antigravity_protocol_tag_regex() -> &'static Regex {
    static PROTOCOL_TAG_REGEX: OnceLock<Regex> = OnceLock::new();
    PROTOCOL_TAG_REGEX.get_or_init(|| {
        Regex::new(r"(?i)</?\s*(?:USER[_-]?REQUEST|SYSTEM[_-]?MESSAGE)\b[^>]*>")
            .expect("valid Antigravity protocol tag regex")
    })
}

fn antigravity_line_gutter_regex() -> &'static Regex {
    static LINE_GUTTER_REGEX: OnceLock<Regex> = OnceLock::new();
    LINE_GUTTER_REGEX.get_or_init(|| {
        Regex::new(r"^(\s*)\d{1,6}\s*(?:[│|:]\s?|\s{2,})(.*)$")
            .expect("valid Antigravity line gutter regex")
    })
}

fn antigravity_ordered_list_line_regex() -> &'static Regex {
    static ORDERED_LIST_LINE_REGEX: OnceLock<Regex> = OnceLock::new();
    ORDERED_LIST_LINE_REGEX
        .get_or_init(|| Regex::new(r"^\s*\d+[.)]\s+\S").expect("valid ordered list guard regex"))
}

fn extract_user_authored_text(text: &str) -> String {
    let request_text = if let Some(index) = find_case_insensitive(text, "## My request for Codex:")
    {
        &text[index + "## My request for Codex:".len()..]
    } else if let Some(index) = find_case_insensitive(text, "My request for Codex:") {
        &text[index + "My request for Codex:".len()..]
    } else {
        text
    };
    strip_generated_context_blocks(request_text)
}

fn strip_generated_context_blocks(text: &str) -> String {
    let mut lines = Vec::<String>::new();
    let mut close_marker: Option<&'static str> = None;
    for line in text.lines() {
        let lower = line.trim_start().to_ascii_lowercase();
        if let Some(close) = close_marker {
            if generated_context_line_contains_close(&lower, close) {
                close_marker = None;
                if let Some(after) = trailing_text_after_context_close(line, close) {
                    if !after.trim().is_empty() {
                        lines.push(after);
                    }
                }
            }
            continue;
        }
        if lower.starts_with("# files mentioned by the user:") {
            continue;
        }
        if let Some(close) = generated_context_block_close_marker(&lower) {
            if generated_context_line_contains_close(&lower, close) {
                if let Some(after) = trailing_text_after_context_close(line, close) {
                    if !after.trim().is_empty() {
                        lines.push(after);
                    }
                }
            } else {
                close_marker = Some(close);
            }
            continue;
        }
        lines.push(line.to_string());
    }
    lines.join("\n")
}

fn trailing_text_after_context_close(line: &str, close: &str) -> Option<String> {
    let lower = line.to_ascii_lowercase();
    let close_lower = close.to_ascii_lowercase();
    lower
        .find(&close_lower)
        .map(|idx| line[idx + close.len()..].to_string())
}

fn generated_context_block_close_marker(lower_line: &str) -> Option<&'static str> {
    for (prefix, close) in [
        ("<command-name", "</command-name>"),
        ("<command", "</command>"),
        ("<image", "</image>"),
        ("<system_message", "</system_message>"),
        ("<system-message", "</system-message>"),
        ("<environment_context", "</environment_context>"),
        ("<app-context", "</app-context>"),
        ("<apps_instructions", "</apps_instructions>"),
        ("<apps-instructions", "</apps-instructions>"),
        ("<skills_instructions", "</skills_instructions>"),
        ("<plugins_instructions", "</plugins_instructions>"),
        ("<recommended_plugins", "</recommended_plugins>"),
        ("<additional_metadata", "</additional_metadata>"),
        ("<collaboration_mode", "</collaboration_mode>"),
        ("<permissions instructions", "</permissions instructions>"),
        ("<system", "</system>"),
        ("<developer", "</developer>"),
        ("<instructions", "</instructions>"),
        ("<local-command-caveat", "</local-command-caveat>"),
        ("<local-command-output", "</local-command-output>"),
        ("<local-command-stdout", "</local-command-stdout>"),
        ("<local-command-stderr", "</local-command-stderr>"),
    ] {
        if lower_line.starts_with(prefix) {
            return Some(close);
        }
    }
    None
}

fn generated_context_line_contains_close(lower_line: &str, close: &str) -> bool {
    lower_line.contains(close)
        || compact_context_marker(lower_line).contains(&compact_context_marker(close))
}

fn compact_context_marker(value: &str) -> String {
    value
        .chars()
        .filter(|ch| !matches!(ch, '_' | '-' | ' ' | '\t'))
        .collect()
}

fn background_context_prompt_text(text: &str) -> bool {
    let lower = text.trim_start().to_ascii_lowercase();
    antigravity_system_boilerplate_text(text)
        || lower.starts_with("# agents.md instructions")
        || lower.starts_with("agents.md instructions")
        || lower.starts_with("<instructions>")
        || lower.starts_with("you are codex, a coding agent")
        || lower.starts_with("you are chatgpt")
        || looks_like_delegated_agent_prompt(text)
        || lower.starts_with("knowledge cutoff:")
        || lower.starts_with("current date:")
        || lower.starts_with("filesystem sandboxing defines")
        || lower.starts_with("sandbox_mode")
        || lower.starts_with("<system")
        || lower.starts_with("<system_message")
        || lower.starts_with("<system-message")
        || lower.starts_with("<developer")
        || lower.starts_with("<app-context")
        || lower.starts_with("<apps_instructions")
        || lower.starts_with("<apps-instructions")
        || lower.starts_with("<environment_context")
        || lower.starts_with("<skills_instructions")
        || lower.starts_with("<plugins_instructions")
        || lower.starts_with("<collaboration_mode")
}

fn antigravity_system_boilerplate_text(text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    !lower.is_empty()
        && ((lower.contains("<system_message>") && lower.contains("not actually sent by the user"))
            || (lower.contains("not actually sent by the user")
                && lower.contains("important information to pay attention"))
            || lower.starts_with("the following is a <system_message>")
            || lower.starts_with("the following is a <system-message>"))
}

fn looks_like_delegated_agent_prompt(text: &str) -> bool {
    let first = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if let Some(rest) = first.strip_prefix("you are a") {
        let digits = rest.chars().take_while(|ch| ch.is_ascii_digit()).count();
        return digits > 0 && rest[digits..].starts_with(':');
    }
    if let Some(rest) = first.strip_prefix("you are agent a") {
        let digits = rest.chars().take_while(|ch| ch.is_ascii_digit()).count();
        return digits > 0 && rest[digits..].starts_with(':');
    }
    if first.starts_with("you are ")
        && first.contains(" worker")
        && (first.contains(" round-")
            || first.contains("worker-")
            || first.contains("codex security")
            || first.contains("you are not the coordinator")
            || first.contains("worker-local"))
    {
        return true;
    }
    false
}

fn delegated_subagent_prompt_title(text: &str) -> Option<String> {
    let first = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    let lower = first.to_ascii_lowercase();
    let rest = lower
        .strip_prefix("you are ")
        .and_then(|_| first.get("You are ".len()..))
        .unwrap_or(first)
        .trim();
    let rest = rest
        .strip_prefix("agent ")
        .or_else(|| rest.strip_prefix("Agent "))
        .unwrap_or(rest)
        .trim();
    let end = rest
        .find(" for ")
        .or_else(|| rest.find(". "))
        .or_else(|| rest.find("。"))
        .unwrap_or(rest.len());
    let title = rest[..end].trim().trim_end_matches('.');
    if title.is_empty() {
        None
    } else {
        Some(title_from_text(title))
    }
}

fn find_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    haystack
        .to_ascii_lowercase()
        .find(&needle.to_ascii_lowercase())
}

fn parse_embedded_json_text(text: &str) -> Option<Value> {
    let trimmed = text.trim();
    let structured = (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']'));
    if !structured {
        return None;
    }
    let value = serde_json::from_str::<Value>(trimmed).ok()?;
    embedded_json_may_hold_message_text(&value, 0).then_some(value)
}

fn embedded_json_may_hold_message_text(value: &Value, depth: usize) -> bool {
    if depth > 6 {
        return false;
    }
    match value {
        Value::Array(items) => items
            .iter()
            .any(|item| embedded_json_may_hold_message_text(item, depth + 1)),
        Value::Object(object) => {
            object.keys().any(|key| {
                matches!(
                    key.as_str(),
                    "text"
                        | "content"
                        | "message"
                        | "messages"
                        | "prompt"
                        | "response"
                        | "answer"
                        | "summary"
                        | "value"
                        | "parts"
                        | "items"
                        | "turns"
                )
            }) || object
                .values()
                .any(|child| embedded_json_may_hold_message_text(child, depth + 1))
        }
        _ => false,
    }
}

fn extract_role(value: &Value) -> String {
    if let Some(type_code) = value.get("type").and_then(Value::as_i64) {
        match type_code {
            1 => return "user".to_string(),
            0 | 2 => return "agent".to_string(),
            _ => {}
        }
    }
    let role = find_string(value, &["role", "author", "speaker", "type", "source"])
        .unwrap_or_else(|| "system".to_string())
        .to_ascii_lowercase();
    if role.contains("user") || role.contains("human") || role == "1" {
        "user".to_string()
    } else if role.contains("assistant")
        || role.contains("agent")
        || role.contains("model")
        || role.contains("ai")
        || role == "0"
        || role == "2"
    {
        "agent".to_string()
    } else if role.contains("tool") {
        "tool".to_string()
    } else {
        role
    }
}

fn extract_timestamp(value: &Value) -> Option<String> {
    find_string(
        value,
        &[
            "createdAt",
            "updatedAt",
            "timestamp",
            "time",
            "date",
            "created_at",
            "updated_at",
        ],
    )
}

fn find_string(value: &Value, keys: &[&str]) -> Option<String> {
    let object = value.as_object()?;
    for key in keys {
        if let Some(text) = object.get(*key).and_then(Value::as_str) {
            return Some(text.to_string());
        }
        if let Some(number) = object.get(*key).and_then(Value::as_i64) {
            return Some(number.to_string());
        }
    }
    if let Some(message) = object.get("message") {
        return find_string(message, keys);
    }
    None
}

fn extract_native_session_id(value: &Value) -> Option<String> {
    find_string(
        value,
        &[
            "sessionId",
            "session_id",
            "conversationId",
            "conversation_id",
            "chatId",
            "chat_id",
            "threadId",
            "thread_id",
            "sessionKey",
            "session_key",
        ],
    )
    .filter(|value| !value.trim().is_empty())
}

fn sqlite_row_key(fields: &[(String, String)]) -> Option<String> {
    for preferred in [
        "key",
        "id",
        "sessionId",
        "session_id",
        "sessionKey",
        "session_key",
        "conversationId",
    ] {
        if let Some((_, value)) = fields
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(preferred))
        {
            if !value.trim().is_empty() {
                return Some(value.trim().to_string());
            }
        }
    }
    None
}

fn sqlite_fields_json(fields: &[(String, String)]) -> Value {
    let mut object = serde_json::Map::<String, Value>::new();
    for (name, value) in fields {
        object.insert(name.clone(), json!(value));
    }
    Value::Object(object)
}

fn sqlite_value_text(value: rusqlite::types::ValueRef<'_>) -> String {
    match value {
        rusqlite::types::ValueRef::Null => String::new(),
        rusqlite::types::ValueRef::Integer(value) => value.to_string(),
        rusqlite::types::ValueRef::Real(value) => value.to_string(),
        rusqlite::types::ValueRef::Text(value) => String::from_utf8_lossy(value).to_string(),
        rusqlite::types::ValueRef::Blob(value) => String::from_utf8_lossy(value).to_string(),
    }
}

fn session_from_messages(
    adapter: HistoryAdapter,
    path: &Path,
    metadata: &fs::Metadata,
    source_kind: &str,
    native_session_id: String,
    messages: Vec<Value>,
) -> Value {
    session_from_messages_with_title(
        adapter,
        path,
        metadata,
        source_kind,
        native_session_id,
        messages,
        None,
    )
}

fn session_from_messages_with_title(
    adapter: HistoryAdapter,
    path: &Path,
    metadata: &fs::Metadata,
    source_kind: &str,
    native_session_id: String,
    messages: Vec<Value>,
    explicit_title: Option<String>,
) -> Value {
    let updated_at = system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH));
    let created_at = system_time(metadata.created().unwrap_or(SystemTime::UNIX_EPOCH));
    let source_client = source_client_for_session(adapter, path, &messages);
    let host_app = host_app_for_path(adapter, path);
    let host_app_label_value = host_app_label(&host_app);
    let source_client_label_value = source_client_label(&source_client);
    let source_label = source_label(&host_app, &source_client);
    let title = explicit_title
        .as_deref()
        .and_then(|title| normalized_explicit_title(adapter, title))
        .or_else(|| title_from_messages(&messages))
        .unwrap_or_else(|| fallback_conversation_title(adapter, path));
    let mut tagged_messages = messages;
    for message in &mut tagged_messages {
        ensure_message_semantic_layer(message);
    }
    let path_display = display_path(path);
    let source_bytes = metadata.len();
    let semantic = match crate::domain::conversation_semantic::build_semantic_conversation(
        &tagged_messages,
        crate::domain::conversation_semantic::SemanticAuditInput {
            adapter_id: adapter.id(),
            adapter_label: adapter.label(),
            host_app: &host_app,
            host_app_label: &host_app_label_value,
            source_client: &source_client,
            source_kind,
            native_session_id: &native_session_id,
            path_ref: &path_display,
            content_hash: "",
            byte_length: source_bytes,
            parse_warnings: &[],
            redaction_status: "applied",
            validation_status: "unchecked",
            created_at: &created_at,
            updated_at: &updated_at,
        },
    ) {
        Ok(value) => value,
        Err(error) => {
            let path_ref = crate::domain::conversation_semantic::synthetic_path_ref(
                adapter.id(),
                &native_session_id,
                source_kind,
            );
            let content_hash = crate::domain::conversation_semantic::hash_text(&format!(
                "semantic-fallback|{}|{}",
                adapter.id(),
                native_session_id
            ));
            let evidence_kind =
                crate::domain::conversation_semantic::evidence_kind_from_source(source_kind);
            json!({
                "schemaVersion": crate::domain::conversation_semantic::SEMANTIC_SCHEMA_VERSION,
                "kind": crate::domain::conversation_semantic::SEMANTIC_KIND,
                "readOnly": true,
                "privacyDefaults": crate::domain::conversation_semantic::privacy_defaults(),
                "thread": [],
                "execution": [],
                "artifacts": [],
                "audit": {
                    "adapterId": adapter.id(),
                    "adapterLabel": adapter.label(),
                    "hostApp": host_app.clone(),
                    "hostAppLabel": host_app_label_value,
                    "sourceClient": source_client.clone(),
                    "sourceKind": source_kind,
                    "nativeSessionId": native_session_id.clone(),
                    "importMode": "precise-adapter",
                    "sourceEvidence": {
                        "kind": evidence_kind,
                        "pathRef": path_ref.clone(),
                        "contentHash": content_hash.clone(),
                        "byteLength": source_bytes
                    },
                    "parseWarnings": [format!("semantic assembly fallback: {error}")],
                    "redactionStatus": "applied",
                    "validationStatus": "failed",
                    "createdAt": created_at.clone(),
                    "updatedAt": updated_at.clone()
                },
                "raw": {
                    "evidenceRefs": [{
                        "kind": evidence_kind,
                        "pathRef": path_ref,
                        "contentHash": content_hash,
                        "byteLength": source_bytes
                    }]
                }
            })
        }
    };
    let mut projected = Vec::new();
    for message in &tagged_messages {
        let layer = message
            .get("layer")
            .and_then(Value::as_str)
            .unwrap_or("execution");
        match layer {
            "thread" => {
                if let Some(event) =
                    crate::domain::conversation_semantic::thread_wire_message_from_tagged(message)
                {
                    projected.push(event);
                }
            }
            "execution" => {
                let role = message.get("role").and_then(Value::as_str).unwrap_or("");
                let card_type = message
                    .get("cardType")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if role == "subagent" || card_type == "subagent" || role == "subagent_prompt" {
                    let mut card = message.clone();
                    crate::domain::conversation_semantic::annotate_message_layer(
                        &mut card,
                        crate::domain::conversation_semantic::SemanticLayer::Execution,
                    );
                    projected.push(card);
                } else if let Some(event) =
                    crate::domain::conversation_semantic::execution_wire_message_from_tagged(
                        message,
                    )
                {
                    projected.push(event);
                }
            }
            _ => {}
        }
    }
    if projected.is_empty() {
        projected =
            crate::domain::conversation_semantic::timeline_messages_from_semantic(&semantic);
    }
    json!({
        "id": session_id(adapter.id(), path, &native_session_id),
        "agentId": adapter.id(),
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sourceTool": source_client.clone(),
        "sourceClient": source_client,
        "sourceClientLabel": source_client_label_value,
        "hostApp": host_app,
        "hostAppLabel": host_app_label_value,
        "sourceLabel": source_label,
        "sourceKind": source_kind,
        "sourcePath": path_display,
        "nativeSessionId": native_session_id,
        "importMode": "precise-adapter",
        "title": title,
        "createdAt": created_at,
        "updatedAt": updated_at,
        "native": true,
        "readOnly": true,
        "messageCount": projected.len(),
        "semantic": semantic,
        "messages": projected
    })
}

fn ensure_message_semantic_layer(message: &mut Value) {
    if message
        .get("layer")
        .and_then(Value::as_str)
        .is_some_and(|layer| !layer.trim().is_empty())
    {
        return;
    }
    let role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let card_type = message
        .get("cardType")
        .and_then(Value::as_str)
        .unwrap_or("");
    let layer = if matches!(role, "transcript" | "record") {
        crate::domain::conversation_semantic::SemanticLayer::Thread
    } else if !card_type.is_empty()
        || matches!(
            role,
            "tool_call"
                | "tool_result"
                | "reasoning"
                | "metadata"
                | "error"
                | "event"
                | "subagent"
                | "subagent_prompt"
        )
    {
        crate::domain::conversation_semantic::SemanticLayer::Execution
    } else if matches!(
        role,
        "user"
            | "human"
            | "assistant"
            | "agent"
            | "model"
            | "ai"
            | "planner-response"
            | "planner_response"
            | "generic"
    ) {
        crate::domain::conversation_semantic::SemanticLayer::Thread
    } else {
        crate::domain::conversation_semantic::SemanticLayer::Execution
    };
    crate::domain::conversation_semantic::annotate_message_layer(message, layer);
}

fn title_from_messages(messages: &[Value]) -> Option<String> {
    for preferred_role in ["user", "human"] {
        if let Some(title) = messages.iter().find_map(|message| {
            let role = message.get("role").and_then(Value::as_str).unwrap_or("");
            if role == preferred_role {
                message
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| title_candidate_text(text))
                    .map(title_from_message_text)
            } else {
                None
            }
        }) {
            return Some(title);
        }
    }
    messages.iter().find_map(|message| {
        let role = message.get("role").and_then(Value::as_str).unwrap_or("");
        if !matches!(role, "transcript" | "record") {
            return None;
        }
        let text = message.get("text").and_then(Value::as_str)?;
        title_from_conversation_marker(text)
    })
}

fn title_from_message_text(text: &str) -> String {
    let cleaned = strip_generated_context_blocks(text);
    let source = if cleaned.trim().is_empty() {
        text
    } else {
        cleaned.as_str()
    };
    if let Some(title) = title_from_conversation_marker(source) {
        return title;
    }
    for line in source
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let lower = line.to_ascii_lowercase();
        for prefix in ["user:", "human:", "prompt:", "question:"] {
            if lower.starts_with(prefix) {
                return title_from_text(line[prefix.len()..].trim());
            }
        }
    }
    title_from_text(source)
}

fn title_from_conversation_marker(text: &str) -> Option<String> {
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let field_value = line.split_once(':').map(|(_, value)| value.trim());
        let candidates = [Some(line), field_value];
        for candidate in candidates.into_iter().flatten() {
            if let Some(title) = title_from_conversation_marker_line(candidate) {
                return Some(title);
            }
        }
    }
    None
}

fn title_from_conversation_marker_line(line: &str) -> Option<String> {
    let lower = line.to_ascii_lowercase();
    for prefix in [
        "user:",
        "human:",
        "prompt:",
        "question:",
        "message:",
        "user message:",
        "human message:",
        "prompt message:",
        "question message:",
    ] {
        if lower.starts_with(prefix) {
            let title = line[prefix.len()..].trim();
            if title_candidate_text(title) {
                return Some(title_from_text(title));
            }
        }
    }
    None
}

fn title_candidate_text(text: &str) -> bool {
    let cleaned = strip_generated_context_blocks(text);
    let trimmed = if cleaned.trim().is_empty() {
        text.trim()
    } else {
        cleaned.trim()
    };
    !trimmed.is_empty()
        && !metadata_like_text(trimmed)
        && !generated_control_text(trimmed)
        && !background_context_prompt_text(trimmed)
}

fn meaningful_explicit_title(title: &str) -> bool {
    let trimmed = title.trim();
    title_candidate_text(trimmed)
        && !looks_like_generated_identity(trimmed)
        && !looks_like_generated_status_title(trimmed)
}

fn normalized_explicit_title(adapter: HistoryAdapter, title: &str) -> Option<String> {
    let cleaned = if matches!(adapter, HistoryAdapter::Antigravity) {
        strip_antigravity_artifact_noise(&extract_antigravity_user_request(title))
    } else {
        title.trim().to_string()
    };
    if meaningful_explicit_title(&cleaned) {
        Some(title_from_text(&cleaned))
    } else {
        None
    }
}

fn extract_conversation_title(value: &Value) -> Option<String> {
    find_string(
        value,
        &[
            "thread_name",
            "threadName",
            "title",
            "name",
            "conversationTitle",
            "chatTitle",
            "sessionTitle",
            "summary",
        ],
    )
    .filter(|title| meaningful_explicit_title(title))
}

fn fallback_conversation_title(adapter: HistoryAdapter, path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    if !stem.is_empty() && !looks_like_generated_identity(stem) {
        return title_from_text(stem);
    }
    format!("{} conversation", adapter.label())
}

fn metadata_like_text(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return true;
    }
    if generated_control_text(trimmed) {
        return true;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("cwd:")
        || lower.starts_with("workingdirectory:")
        || lower.starts_with("projectpath:")
        || lower.starts_with("codex event:")
        || lower.starts_with("<environment_context>")
        || lower.starts_with("<apps_instructions>")
        || lower.starts_with("<apps-instructions>")
    {
        return true;
    }
    let line_count = trimmed.lines().count().max(1);
    let key_value_lines = trimmed
        .lines()
        .filter(|line| {
            let line = line.trim();
            line.contains(':') && !line.contains(' ') && line.len() < 80
        })
        .count();
    key_value_lines == line_count && line_count <= 4
}

fn generated_control_text(text: &str) -> bool {
    let lower = text.trim_start().to_ascii_lowercase();
    lower.starts_with("<local-command-caveat>")
        || lower.starts_with("<command-name")
        || lower.starts_with("<command")
        || lower.starts_with("<local-command-output>")
        || lower.starts_with("<local-command-stdout>")
        || lower.starts_with("<local-command-stderr>")
        || lower.starts_with("<local-command-exit-code>")
        || lower.starts_with("<local-command-timeout>")
        || lower.starts_with("<environment_context>")
        || lower.starts_with("<apps_instructions>")
        || lower.starts_with("<apps-instructions>")
        || lower.starts_with("<recommended_plugins")
        || lower.starts_with("<additional_metadata")
        || lower.starts_with("<plugins_instructions")
        || background_context_prompt_text(text)
        || (lower.contains("<local-command-caveat>") && lower.contains("do not respond"))
}

fn looks_like_generated_status_title(value: &str) -> bool {
    let lower = value.trim().to_ascii_lowercase();
    lower.starts_with("updated ")
        || lower.starts_with("created ")
        || lower.starts_with("deleted ")
        || lower.starts_with("renamed ")
        || lower.starts_with("moved ")
        || lower.starts_with("indexed ")
        || lower.starts_with("the conversation has been cleared")
        || lower.starts_with("conversation has been cleared")
}

fn looks_like_generated_identity(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty() {
        return true;
    }
    if looks_like_uuid(value) {
        return true;
    }
    let compact = value.replace(['-', '_'], "");
    compact.len() >= 16 && compact.chars().all(|ch| ch.is_ascii_hexdigit())
}

fn source_client_for_session(adapter: HistoryAdapter, path: &Path, messages: &[Value]) -> String {
    let evidence = source_evidence_text(path, messages);
    if evidence.contains("github.copilot")
        || evidence.contains("copilot-chat")
        || evidence.contains("chat-session-resources")
    {
        return "copilot".to_string();
    }
    if evidence.contains("kilo-code")
        || evidence.contains("kilocode")
        || evidence.contains("/kilo/")
        || evidence.contains("\\kilo\\")
    {
        return "kilo-code".to_string();
    }
    adapter.id().to_string()
}

fn source_evidence_text(path: &Path, messages: &[Value]) -> String {
    let mut parts = vec![path.to_string_lossy().replace('\\', "/")];
    for message in messages.iter().take(8) {
        for key in ["sourcePath", "sourceKey", "sourceTable"] {
            if let Some(text) = message.get(key).and_then(Value::as_str) {
                parts.push(text.replace('\\', "/"));
            }
        }
    }
    parts.join("\n").to_ascii_lowercase()
}

fn host_app_for_path(adapter: HistoryAdapter, path: &Path) -> String {
    let path_text = path
        .to_string_lossy()
        .replace('\\', "/")
        .to_ascii_lowercase();
    if path_text.contains("/library/application support/code/")
        || path_text.contains("/.config/code/")
        || path_text.contains("/appdata/roaming/code/")
    {
        return "vscode".to_string();
    }
    if path_text.contains("/library/application support/cursor/")
        || path_text.contains("/.config/cursor/")
    {
        return "cursor".to_string();
    }
    if path_text.contains("antigravity ide") || path_text.contains("/.gemini/antigravity") {
        return "antigravity".to_string();
    }
    adapter.id().to_string()
}

fn source_label(host_app: &str, source_client: &str) -> String {
    let source = source_client_display(source_client);
    if !host_app.is_empty() && host_app != source_client {
        format!("{}: {}", host_app_display(host_app), source)
    } else {
        source.to_string()
    }
}

fn source_client_label(source_client: &str) -> &'static str {
    match source_client {
        "antigravity" => "Antigravity",
        "claude-code" => "Claude Code",
        "code" => "VS Code",
        "codex" => "Codex",
        "copilot" => "GitHub Copilot",
        "cursor" => "Cursor",
        "hermes" => "Hermes Agent",
        "kilo-code" => "Kilo Code",
        "kimi" => "Kimi",
        "openclaw" => "OpenClaw",
        "opencode" => "OpenCode",
        "pi" => "Pi Agent",
        _ => "Native Conversation",
    }
}

fn host_app_label(host_app: &str) -> &'static str {
    match host_app {
        "antigravity" => "Antigravity",
        "claude-code" => "Claude Code",
        "code" | "vscode" => "VS Code",
        "codex" => "Codex",
        "copilot" => "GitHub Copilot",
        "cursor" => "Cursor",
        "hermes" => "Hermes Agent",
        "kilo-code" => "Kilo Code",
        "kimi" => "Kimi",
        "openclaw" => "OpenClaw",
        "opencode" => "OpenCode",
        "pi" => "Pi Agent",
        _ => "Native Host",
    }
}

fn source_client_display(source_client: &str) -> &'static str {
    match source_client {
        "claude-code" => "claude code",
        "code" | "vscode" => "vscode",
        "copilot" => "copilot",
        "kilo-code" => "kilo code",
        "openclaw" => "openclaw",
        "opencode" => "opencode",
        "antigravity" => "antigravity",
        "codex" => "codex",
        "cursor" => "cursor",
        "hermes" => "hermes",
        "kimi" => "kimi",
        "pi" => "pi",
        _ => "conversation",
    }
}

fn host_app_display(host_app: &str) -> &'static str {
    match host_app {
        "code" | "vscode" => "vscode",
        "kilo-code" => "kilo code",
        "claude-code" => "claude code",
        "openclaw" => "openclaw",
        "opencode" => "opencode",
        "antigravity" => "antigravity",
        "codex" => "codex",
        "copilot" => "copilot",
        "cursor" => "cursor",
        "hermes" => "hermes",
        "kimi" => "kimi",
        "pi" => "pi",
        _ => "native",
    }
}

fn history_roots(adapter: HistoryAdapter, params: &Value) -> Vec<HistoryRoot> {
    if let Some(root) = text_param(params, &["root", "historyRoot"]) {
        if !root.is_empty() {
            return vec![HistoryRoot {
                path: expand_home(&root),
                source_kind: text_param(params, &["historyRootKind", "rootKind"])
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| "override-root".to_string()),
            }];
        }
    }
    let home_override = text_param(params, &["homeDir"])
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let home = home_override.clone().unwrap_or_else(home_dir);
    let appdata = home_override
        .as_ref()
        .map(|path| appdata_dir_from_home(path))
        .unwrap_or_else(appdata_dir);
    let local_appdata = home_override
        .as_ref()
        .map(|path| local_appdata_dir_from_home(path))
        .unwrap_or_else(local_appdata_dir);
    let xdg_config = home_override
        .as_ref()
        .map(|path| xdg_config_dir_from_home(path))
        .unwrap_or_else(xdg_config_dir);
    let xdg_data = home_override
        .as_ref()
        .map(|path| xdg_data_dir_from_home(path))
        .unwrap_or_else(xdg_data_dir);
    let kimi_code_home = kimi_code_history_home(params, &home, home_override.is_none());
    match adapter {
        HistoryAdapter::Codex => roots(&[
            (home.join(".codex/history.jsonl"), "codex-prompt-history"),
            (
                home.join(".codex/session_index.jsonl"),
                "codex-session-index",
            ),
            (home.join(".codex/sessions"), "codex-session-store"),
            (
                home.join(".codex/archived_sessions"),
                "codex-archived-session-store",
            ),
            (home.join(".codex/memories/MEMORY.md"), "codex-memory"),
            (
                home.join(".codex/memories/rollout_summaries"),
                "codex-rollout-summary",
            ),
        ]),
        HistoryAdapter::Antigravity => roots(&[
            (
                home.join("Library/Application Support/Antigravity IDE"),
                "antigravity-ide-state",
            ),
            (appdata.join("Antigravity IDE"), "antigravity-ide-state"),
            (
                local_appdata.join("Antigravity IDE"),
                "antigravity-ide-state",
            ),
            (xdg_config.join("Antigravity IDE"), "antigravity-ide-state"),
            (home.join(".gemini/antigravity"), "antigravity-bridge"),
            (home.join(".gemini/antigravity-ide"), "antigravity-bridge"),
        ]),
        HistoryAdapter::ClaudeCode => roots(&[
            (home.join(".claude/projects"), "claude-project-transcripts"),
            (home.join(".claude.json"), "claude-global-state"),
        ]),
        HistoryAdapter::Cursor => roots(&[
            (
                home.join("Library/Application Support/Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
            (
                appdata.join("Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                appdata.join("Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
            (
                xdg_config.join("Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                xdg_config.join("Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
        ]),
        HistoryAdapter::Code => roots(&[
            (
                home.join("Library/Application Support/Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Code/User/globalStorage"),
                "vscode-global-storage",
            ),
            (
                appdata.join("Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                appdata.join("Code/User/globalStorage"),
                "vscode-global-storage",
            ),
            (
                xdg_config.join("Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                xdg_config.join("Code/User/globalStorage"),
                "vscode-global-storage",
            ),
        ]),
        HistoryAdapter::Copilot => roots(&[
            (
                home.join("Library/Application Support/Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
            (
                appdata.join("Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                appdata.join("Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
            (
                xdg_config.join("Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                xdg_config.join("Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
        ]),
        HistoryAdapter::KiloCode => roots(&[
            (
                home.join(".local/share/kilo/kilo.db"),
                "kilo-session-database",
            ),
            (
                home.join(".local/share/kilo/storage/session_diff"),
                "kilo-session-diff",
            ),
            (
                home.join(".local/share/kilo/storage/session_share"),
                "kilo-session-share",
            ),
            (home.join(".local/share/kilo/log"), "kilo-log"),
            (home.join(".config/kilo"), "kilo-config"),
            (appdata.join("kilo"), "kilo-appdata"),
            (xdg_data.join("kilo"), "kilo-data"),
        ]),
        HistoryAdapter::OpenCode => roots(&[
            (home.join(".config/opencode"), "opencode-config"),
            (home.join(".local/share/opencode"), "opencode-data"),
            (appdata.join("opencode"), "opencode-appdata"),
            (xdg_data.join("opencode"), "opencode-data"),
        ]),
        HistoryAdapter::OpenClaw => roots(&[
            (home.join(".openclaw"), "openclaw-home"),
            (home.join(".config/openclaw"), "openclaw-config"),
            (appdata.join("OpenClaw"), "openclaw-appdata"),
            (xdg_config.join("openclaw"), "openclaw-config"),
        ]),
        HistoryAdapter::Hermes => roots(&[
            (home.join(".hermes"), "hermes-home"),
            (home.join(".config/hermes"), "hermes-config"),
            (appdata.join("Hermes"), "hermes-appdata"),
            (xdg_config.join("hermes"), "hermes-config"),
        ]),
        HistoryAdapter::Kimi => roots(&[
            (
                home.join("Library/Application Support/Kimi"),
                "kimi-app-state",
            ),
            (
                home.join("Library/Application Support/com.moonshot.kimi"),
                "kimi-app-state",
            ),
            (home.join("Library/Logs/Kimi"), "kimi-log"),
            (appdata.join("Kimi"), "kimi-appdata"),
            (appdata.join("com.moonshot.kimi"), "kimi-appdata"),
            (local_appdata.join("Kimi"), "kimi-local-appdata"),
            (xdg_config.join("Kimi"), "kimi-config"),
            (xdg_data.join("Kimi"), "kimi-data"),
        ]),
        HistoryAdapter::KimiCode => {
            roots(&[(kimi_code_home.join("sessions"), "kimi-code-session-store")])
        }
        HistoryAdapter::Pi => roots(&[
            (home.join(".pi/agent/sessions"), "pi-session-store"),
            (home.join(".pi/agent"), "pi-agent-home"),
        ]),
    }
}

fn kimi_code_history_home(params: &Value, home: &Path, allow_environment: bool) -> PathBuf {
    let configured = text_param(params, &["kimiCodeHome"]).or_else(|| {
        allow_environment
            .then(|| env::var("KIMI_CODE_HOME").ok())
            .flatten()
    });
    configured
        .map(|value| expand_home_from(&value, || home.to_path_buf()))
        .unwrap_or_else(|| home.join(".kimi-code"))
}

fn roots(items: &[(PathBuf, &'static str)]) -> Vec<HistoryRoot> {
    items
        .iter()
        .map(|(path, source_kind)| HistoryRoot {
            path: path.clone(),
            source_kind: source_kind.to_string(),
        })
        .collect()
}

fn looks_like_history_text(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("assistant")
        || lower.contains("user")
        || lower.contains("prompt")
        || lower.contains("message")
        || lower.contains("conversation")
        || lower.contains("chat")
}

fn looks_like_text_conversation(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    let structured_text = looks_like_structured_text(raw);
    let has_user_marker = (structured_text
        && (lower.contains("\"role\":\"user\"") || lower.contains("\"role\": \"user\"")))
        || lower.contains("role: user")
        || lower.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with("user:")
                || line.starts_with("human:")
                || line.starts_with("prompt:")
                || line.starts_with("question:")
        });
    let has_response_marker = (structured_text
        && (lower.contains("\"role\":\"assistant\"")
            || lower.contains("\"role\": \"assistant\"")
            || lower.contains("\"role\":\"agent\"")
            || lower.contains("\"role\": \"agent\"")))
        || lower.contains("role: assistant")
        || lower.contains("role: agent")
        || lower.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with("assistant:")
                || line.starts_with("agent:")
                || line.starts_with("response:")
                || line.starts_with("answer:")
        });
    if has_user_marker && has_response_marker {
        return true;
    }
    structured_text && lower.contains("\"messages\"") && (has_user_marker || has_response_marker)
}

fn looks_like_structured_text(raw: &str) -> bool {
    let trimmed = raw.trim_start();
    trimmed.starts_with('{') || trimmed.starts_with('[')
}

fn history_match_text(session: &Value) -> String {
    let mut parts = Vec::<String>::new();
    for key in ["title", "nativeSessionId"] {
        if let Some(text) = session.get(key).and_then(Value::as_str) {
            parts.push(text.to_string());
        }
    }
    if let Some(messages) = session.get("messages").and_then(Value::as_array) {
        for message in messages {
            if !history_message_is_matchable(message) {
                continue;
            }
            if let Some(text) = message.get("text").and_then(Value::as_str) {
                parts.push(text.to_string());
            }
        }
    }
    parts.join("\n")
}

fn history_match_path_text(session: &Value) -> String {
    let mut parts = Vec::<String>::new();
    for key in ["sourcePath", "workingDirectory", "cwd", "projectPath"] {
        if let Some(text) = session.get(key).and_then(Value::as_str) {
            parts.push(text.to_string());
        }
    }
    if let Some(messages) = session.get("messages").and_then(Value::as_array) {
        for message in messages {
            for key in ["sourcePath", "workingDirectory", "cwd", "projectPath"] {
                if let Some(text) = message.get(key).and_then(Value::as_str) {
                    parts.push(text.to_string());
                }
            }
        }
    }
    parts.join("\n")
}

fn source_path_is_sqlite(session: &Value) -> bool {
    let extension = session
        .get("sourcePath")
        .and_then(Value::as_str)
        .and_then(|path| Path::new(path).extension())
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(extension.as_str(), "sqlite" | "sqlite3" | "db" | "vscdb")
}

fn history_message_is_matchable(message: &Value) -> bool {
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        role.as_str(),
        "user" | "human" | "assistant" | "agent" | "model"
    ) || (matches!(role.as_str(), "transcript" | "")
        && message
            .get("text")
            .and_then(Value::as_str)
            .map(looks_like_text_conversation)
            .unwrap_or(false))
        || (role == "record"
            && message
                .get("text")
                .and_then(Value::as_str)
                .map(looks_like_database_record)
                .unwrap_or(false))
}

fn history_session_has_real_conversation(session: &Value) -> bool {
    session
        .get("messages")
        .and_then(Value::as_array)
        .map(|messages| messages.iter().any(history_message_is_matchable))
        .unwrap_or(false)
}

fn history_message_is_user_authored(message: &Value) -> bool {
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if matches!(role.as_str(), "user" | "human") {
        return title_candidate_text(text);
    }
    if matches!(role.as_str(), "transcript" | "record" | "") {
        return title_from_conversation_marker(text).is_some();
    }
    false
}

fn history_session_has_user_authored_message(session: &Value) -> bool {
    session
        .get("messages")
        .and_then(Value::as_array)
        .map(|messages| messages.iter().any(history_message_is_user_authored))
        .unwrap_or(false)
}

fn looks_like_database_record(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("message:")
        || lower.contains("messages:")
        || lower.contains("conversation:")
        || lower.contains("conversations:")
        || lower.contains("chat:")
        || lower.contains("chats:")
}

fn normalize_history_match_text(value: &str) -> String {
    let mut out = String::new();
    let mut separator = false;
    for ch in value.chars() {
        if ch.is_whitespace() || ch == '-' || ch == '_' {
            separator = true;
            continue;
        }
        if separator && !out.is_empty() {
            out.push('-');
        }
        separator = false;
        for lower in ch.to_lowercase() {
            if lower.is_ascii_alphanumeric() || !lower.is_control() {
                out.push(lower);
            }
        }
    }
    out
}

fn normalized_contains_history_term(normalized: &str, term: &str) -> bool {
    normalized.match_indices(term).any(|(index, _)| {
        let before = normalized[..index].chars().next_back();
        let after = normalized[index + term.len()..].chars().next();
        history_identity_boundary(before) && history_identity_boundary(after)
    })
}

fn history_identity_boundary(ch: Option<char>) -> bool {
    ch.map(|ch| !ch.is_ascii_alphanumeric()).unwrap_or(true)
}

fn extract_json_from_text(text: &str) -> Option<Value> {
    for part in text.split('\n') {
        let trimmed = part.trim();
        if let Some(start) = trimmed.find('{') {
            if let Ok(value) = serde_json::from_str::<Value>(&trimmed[start..]) {
                return Some(value);
            }
        }
        if let Some(start) = trimmed.find('[') {
            if let Ok(value) = serde_json::from_str::<Value>(&trimmed[start..]) {
                return Some(value);
            }
        }
    }
    None
}

fn agent_param(params: &Value) -> Result<String> {
    text_param(params, &["agent", "agentId", "target"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("conversation command requires --agent"))
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn number_param(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(|value| {
        value.as_u64().or_else(|| {
            value
                .as_str()
                .and_then(|text| text.trim().parse::<u64>().ok())
        })
    })
}

fn string_list_param(params: &Value, keys: &[&str]) -> Vec<String> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .map(|value| match value {
            Value::Array(items) => items
                .iter()
                .filter_map(Value::as_str)
                .flat_map(split_string_list)
                .collect(),
            Value::String(text) => split_string_list(text).collect(),
            _ => Vec::new(),
        })
        .unwrap_or_default()
}

fn split_string_list(value: &str) -> impl Iterator<Item = String> + '_ {
    value
        .split([',', '\n'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn param_bool(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| match value {
        Value::Bool(value) => Some(*value),
        Value::String(value) => match value.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

fn title_from_text(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 64 {
        compact
    } else {
        format!("{}...", compact.chars().take(64).collect::<String>())
    }
}

fn session_id(agent_id: &str, path: &Path, native_session_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(agent_id.as_bytes());
    hasher.update(path.to_string_lossy().as_bytes());
    hasher.update(native_session_id.as_bytes());
    format!("native-{:x}", hasher.finalize())
}

fn message_id(agent_id: &str, path: &Path, index: usize) -> String {
    let mut hasher = Sha256::new();
    hasher.update(agent_id.as_bytes());
    hasher.update(path.to_string_lossy().as_bytes());
    hasher.update(index.to_string().as_bytes());
    format!("msg-{:x}", hasher.finalize())
}

fn home_dir() -> PathBuf {
    home_dir_from_env(|name| env::var_os(name))
}

fn home_dir_from_env<F>(var: F) -> PathBuf
where
    F: Fn(&str) -> Option<OsString>,
{
    if let Some(path) = env_path_from(&var, "HOME") {
        return path;
    }
    if let Some(path) = env_path_from(&var, "USERPROFILE") {
        return path;
    }
    if let (Some(mut drive), Some(path)) = (var("HOMEDRIVE"), var("HOMEPATH")) {
        if !drive.is_empty() && !path.is_empty() {
            drive.push(path);
            return PathBuf::from(drive);
        }
    }
    directories::UserDirs::new()
        .map(|dirs| dirs.home_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

fn env_path(name: &str) -> Option<PathBuf> {
    env_path_from(&|key| env::var_os(key), name)
}

fn env_path_from<F>(var: &F, name: &str) -> Option<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    var(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn appdata_dir() -> PathBuf {
    env_path("APPDATA").unwrap_or_else(|| {
        if cfg!(windows) {
            home_dir().join("AppData").join("Roaming")
        } else {
            xdg_config_dir()
        }
    })
}

fn appdata_dir_from_home(home: &Path) -> PathBuf {
    if cfg!(windows) {
        home.join("AppData").join("Roaming")
    } else {
        xdg_config_dir_from_home(home)
    }
}

fn local_appdata_dir() -> PathBuf {
    env_path("LOCALAPPDATA").unwrap_or_else(|| {
        if cfg!(windows) {
            home_dir().join("AppData").join("Local")
        } else {
            xdg_data_dir()
        }
    })
}

fn local_appdata_dir_from_home(home: &Path) -> PathBuf {
    if cfg!(windows) {
        home.join("AppData").join("Local")
    } else {
        xdg_data_dir_from_home(home)
    }
}

fn xdg_config_dir() -> PathBuf {
    env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home_dir().join(".config"))
}

fn xdg_config_dir_from_home(home: &Path) -> PathBuf {
    home.join(".config")
}

fn xdg_data_dir() -> PathBuf {
    env_path("XDG_DATA_HOME").unwrap_or_else(|| home_dir().join(".local/share"))
}

fn xdg_data_dir_from_home(home: &Path) -> PathBuf {
    home.join(".local/share")
}

fn expand_home(value: &str) -> PathBuf {
    expand_home_from(value, home_dir)
}

fn expand_home_from<F>(value: &str, home: F) -> PathBuf
where
    F: Fn() -> PathBuf,
{
    if value == "~" {
        return home();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return home().join(rest);
    }
    if let Some(rest) = value.strip_prefix("~\\") {
        return home().join(rest);
    }
    PathBuf::from(value)
}

fn system_time(time: SystemTime) -> String {
    let duration = time.duration_since(UNIX_EPOCH).unwrap_or_default();
    OffsetDateTime::from_unix_timestamp(duration.as_secs() as i64)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn epoch_value_to_rfc3339(value: &Value) -> Option<String> {
    value
        .as_i64()
        .or_else(|| {
            value
                .as_str()
                .and_then(|text| text.trim().parse::<i64>().ok())
        })
        .and_then(epoch_number_to_rfc3339)
}

fn epoch_number_to_rfc3339(value: i64) -> Option<String> {
    if value <= 0 {
        return None;
    }
    let absolute = (value as i128).abs();
    let seconds = if absolute >= 1_000_000_000_000_000 {
        value / 1_000_000
    } else if absolute >= 10_000_000_000 {
        value / 1_000
    } else {
        value
    };
    OffsetDateTime::from_unix_timestamp(seconds)
        .ok()
        .and_then(|time| time.format(&Rfc3339).ok())
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn exact_session_filter_matches_projection_or_native_identity() {
        let projection = HistoryScanConfig::from_params(&json!({
            "sessionId": "projection-1"
        }));
        let native = HistoryScanConfig::from_params(&json!({
            "sessionId": "native-1"
        }));
        let other = HistoryScanConfig::from_params(&json!({
            "sessionId": "other"
        }));
        let multiple = HistoryScanConfig::from_params(&json!({
            "sessionIds": ["projection-1", "other"]
        }));
        let session = json!({
            "id": "projection-1",
            "nativeSessionId": "native-1",
            "messages": []
        });

        assert!(projection.has_single_session_filter());
        assert!(!multiple.has_single_session_filter());
        assert!(projection.matches_session(&session));
        assert!(native.matches_session(&session));
        assert!(!other.matches_session(&session));
    }

    #[test]
    fn default_history_home_uses_windows_userprofile_when_home_is_missing() {
        let resolved = home_dir_from_env(|name| match name {
            "USERPROFILE" => Some(OsString::from(r"C:\Profile\LicoLite")),
            _ => None,
        });

        assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
    }

    #[test]
    fn default_history_home_uses_windows_drive_and_homepath_fallback() {
        let resolved = home_dir_from_env(|name| match name {
            "HOMEDRIVE" => Some(OsString::from("C:")),
            "HOMEPATH" => Some(OsString::from(r"\Profile\LicoLite")),
            _ => None,
        });

        assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
    }

    #[test]
    fn expand_home_accepts_windows_style_tilde_paths() {
        let expanded = expand_home_from(r"~\.codex\sessions", || {
            PathBuf::from(r"C:\Profile\LicoLite")
        });

        assert_eq!(
            expanded,
            PathBuf::from(r"C:\Profile\LicoLite").join(r".codex\sessions")
        );
    }

    #[test]
    fn history_roots_follow_home_override_for_xdg_backed_targets() {
        let home = temp_dir("history-home-override");

        let cursor = history_roots(
            HistoryAdapter::Cursor,
            &json!({"homeDir": display_path(&home)}),
        );
        let code = history_roots(
            HistoryAdapter::Code,
            &json!({"homeDir": display_path(&home)}),
        );
        let copilot = history_roots(
            HistoryAdapter::Copilot,
            &json!({"homeDir": display_path(&home)}),
        );

        assert!(
            cursor
                .iter()
                .any(|root| root.path == home.join(".config/Cursor/User/workspaceStorage"))
        );
        assert!(
            code.iter()
                .any(|root| root.path == home.join(".config/Code/User/workspaceStorage"))
        );
        assert!(
            copilot
                .iter()
                .any(|root| root.path == home.join(".config/Code/User/globalStorage"))
        );
    }

    #[test]
    fn history_roots_cover_kimi_app_data_locations() {
        let home = temp_dir("history-kimi-roots");

        let roots = history_roots(
            HistoryAdapter::Kimi,
            &json!({"homeDir": display_path(&home)}),
        );

        assert!(
            roots
                .iter()
                .any(|root| root.path == home.join("Library/Application Support/Kimi"))
        );
        assert!(roots.iter().any(|root| root.path
            == home.join("Library/Application Support/com.moonshot.kimi")));
        assert!(
            roots
                .iter()
                .any(|root| root.path == home.join(".config/Kimi"))
        );
        assert!(
            roots
                .iter()
                .any(|root| root.path == home.join(".local/share/Kimi"))
        );
    }

    #[test]
    fn kimi_code_history_roots_are_isolated_from_desktop_history() {
        let home = temp_dir("history-kimi-code-roots");
        let custom = home.join("custom-kimi-code");

        let default_roots = history_roots(
            HistoryAdapter::KimiCode,
            &json!({"homeDir": display_path(&home)}),
        );
        assert_eq!(default_roots[0].path, home.join(".kimi-code/sessions"));
        assert_eq!(default_roots[0].source_kind, "kimi-code-session-store");
        assert_eq!(default_roots.len(), 1);

        let custom_roots = history_roots(
            HistoryAdapter::KimiCode,
            &json!({
                "homeDir": display_path(&home),
                "kimiCodeHome": display_path(&custom),
            }),
        );
        assert_eq!(custom_roots[0].path, custom.join("sessions"));
        assert!(HistoryAdapter::KimiCode.accepts_file(
            &custom.join("sessions/wd/session/agents/main/wire.jsonl"),
            "jsonl",
        ));
        assert!(
            !HistoryAdapter::KimiCode
                .accepts_file(&custom.join("sessions/wd/session/state.json"), "json",)
        );
    }

    #[test]
    fn pi_session_jsonl_history_preserves_native_session_and_roles() {
        let root = temp_dir("pi-session-history");
        let session = root.join("--workspace--/20260101T000000_pi-native-session.jsonl");
        fs::create_dir_all(session.parent().unwrap()).unwrap();
        fs::write(
            &session,
            [
                r#"{"type":"session","version":3,"id":"pi-native-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/workspace/project"}"#,
                r#"{"type":"session_info","id":"n1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","name":"Pi fixture"}"#,
                r#"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":"List the fixtures"}}"#,
                r#"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Found one fixture"}],"stopReason":"stop"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "pi",
            "root": display_path(&root),
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "pi");
        assert_eq!(sessions[0]["adapterLabel"], "Pi Agent - CLI");
        assert_eq!(sessions[0]["nativeSessionId"], "pi-native-session");
        assert_eq!(sessions[0]["title"], "Pi fixture");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert!(messages.iter().any(|message| {
            message["role"] == "user" && message["text"] == "List the fixtures"
        }));
        assert!(messages.iter().any(|message| {
            message["role"] == "agent" && message["text"] == "Found one fixture"
        }));
    }

    #[test]
    fn kimi_code_wire_usage_records_preserve_model_and_exact_token_fields() {
        let root = temp_dir("kimi-code-wire");
        let wire = root.join("wd_project/session-1/agents/main/wire.jsonl");
        fs::create_dir_all(wire.parent().unwrap()).unwrap();
        fs::write(
            &wire,
            [
                r#"{"type":"metadata","protocol_version":1}"#,
                r#"{"type":"context.append_message","time":1780912800000,"message":{"role":"user","content":"Review the synthetic Kimi Code fixture"}}"#,
                r#"{"type":"usage.record","time":1780912801000,"model":"kimi-code/kimi-for-coding","usageScope":"turn","usage":{"inputOther":100,"inputCacheRead":20,"inputCacheCreation":5,"output":30}}"#,
                r#"{"type":"usage.record","time":1780912802000,"model":"kimi-code/kimi-for-coding","usageScope":"session","usage":{"inputOther":9999,"inputCacheRead":0,"inputCacheCreation":0,"output":9999}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "kimi-code",
            "root": display_path(&root),
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "kimi-code");
        assert_eq!(sessions[0]["adapterLabel"], "Kimi Code - CLI");
        assert_eq!(sessions[0]["nativeSessionId"], "session-1");

        let messages = sessions[0]["messages"].as_array().unwrap();
        assert!(messages.iter().any(|message| {
            message["role"] == "user" && message["text"] == "Review the synthetic Kimi Code fixture"
        }));
        let usage = messages
            .iter()
            .find(|message| message["sourceEventType"] == "usage.record")
            .unwrap();
        assert_eq!(usage["model"], "kimi-code/kimi-for-coding");
        assert_eq!(usage["usage"]["promptTokens"], 125);
        assert_eq!(usage["usage"]["cachedInputTokens"], 20);
        assert_eq!(usage["usage"]["completionTokens"], 30);
        assert_eq!(usage["usage"]["totalTokens"], 155);
        assert_eq!(
            messages
                .iter()
                .filter(|message| message["sourceEventType"] == "usage.record")
                .count(),
            1,
        );
    }

    #[test]
    fn kimi_code_wire_readback_preserves_session_and_structured_order() {
        let root = temp_dir("kimi-code-structured-wire");
        let session_root = root.join("work-key/native-session-42");
        let wire = session_root.join("agents/main/wire.jsonl");
        fs::create_dir_all(wire.parent().unwrap()).unwrap();
        fs::write(
            session_root.join("state.json"),
            r#"{"title":"Synthetic Kimi Code session"}"#,
        )
        .unwrap();
        let reasoning_canary = "PRIVATE_REASONING_CANARY";
        let argument_canary = "api_key=PRIVATE_ARGUMENT_CANARY";
        fs::write(
            &wire,
            [
                r#"{"type":"turn.prompt","turnId":"turn-1","time":"2026-07-10T00:00:00Z","input":"Kimi Code synthetic prompt"}"#,
                &format!(r#"{{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:01Z","event":{{"type":"content.part","step":1,"part":{{"type":"think","think":"{reasoning_canary} "}}}}}}"#),
                r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:01Z","event":{"type":"content.part","step":1,"part":{"type":"think","think":"second private chunk"}}}"#,
                &format!(r#"{{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:02Z","event":{{"type":"tool.call","name":"exec","arguments":{{"command":"{argument_canary}"}}}}}}"#),
                r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:03Z","event":{"type":"tool.result","name":"exec","result":"completed"}}"#,
                r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:04Z","event":{"type":"content.part","step":2,"part":{"type":"text","text":"Final "}}}"#,
                r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:04Z","event":{"type":"content.part","step":2,"part":{"type":"text","text":"answer"}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "kimi-code",
            "root": display_path(&root),
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "kimi-code");
        assert_eq!(sessions[0]["adapterLabel"], "Kimi Code - CLI");
        assert_eq!(sessions[0]["nativeSessionId"], "native-session-42");

        let messages = sessions[0]["messages"].as_array().unwrap();
        let roles = messages
            .iter()
            .map(|message| message["role"].as_str().unwrap_or_default())
            .collect::<Vec<_>>();
        assert_eq!(
            roles,
            vec!["user", "reasoning", "tool_call", "tool_result", "agent"]
        );
        assert_eq!(messages[0]["text"], "Kimi Code synthetic prompt");
        assert_eq!(messages[1]["text"], "Reasoning details are redacted.");
        assert!(messages[1].get("providerSummary").is_none());
        assert_eq!(messages[2]["cardType"], "tool-call");
        assert_eq!(messages[2]["text"], "Invocation details are hidden.");
        assert_eq!(messages[3]["cardType"], "tool-result");
        assert_eq!(messages[4]["text"], "Final answer");
        assert_eq!(
            messages
                .iter()
                .filter(|message| message["role"] == "reasoning")
                .count(),
            1
        );
        assert_eq!(
            messages
                .iter()
                .filter(|message| message["role"] == "agent")
                .count(),
            1
        );
        let serialized = serde_json::to_string(messages).unwrap();
        assert!(!serialized.contains(reasoning_canary));
        assert!(!serialized.contains(argument_canary));
    }

    #[test]
    fn conversations_scan_codex_jsonl_history() {
        let dir = temp_dir("codex-history");
        let history = dir.join("history.jsonl");
        fs::write(
            &history,
            [
                r#"{"role":"user","content":"Build LicoLite native history","createdAt":"2026-06-12T00:00:00Z"}"#,
                r#"{"role":"assistant","content":"Use Codex history adapter","createdAt":"2026-06-12T00:00:01Z"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(listed["mode"], "native-history");
        assert_eq!(listed["readOnly"], true);
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["agentId"], "codex");
        assert_eq!(sessions[0]["native"], true);
        assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
        assert_eq!(
            sessions[0]["messages"][0]["text"],
            "Build LicoLite native history"
        );
    }

    #[test]
    fn pure_startup_logs_are_not_native_conversations() {
        let dir = temp_dir("startup-log-history");
        fs::write(
            dir.join("opencode.log"),
            [
                r#"INFO 2026-06-20T00:00:00Z args=["mcp","list"] opencode"#,
                "INFO service=config path=<user-home>/.config/opencode/config.json",
                "INFO directory=/workspace/licolite creating instance",
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(listed["sessions"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn sqlite_history_files_can_exceed_text_byte_limit() {
        assert!(history_file_can_exceed_byte_limit(
            HistoryAdapter::OpenCode,
            Path::new("opencode.db")
        ));
        assert!(history_file_can_exceed_byte_limit(
            HistoryAdapter::KiloCode,
            Path::new("kilo.db")
        ));
        assert!(!history_file_can_exceed_byte_limit(
            HistoryAdapter::OpenCode,
            Path::new("opencode.log")
        ));
    }

    #[test]
    fn explicit_total_reconciles_inclusive_cache_read_tokens() {
        let usage = extract_token_usage(&json!({
            "usage": {
                "input_tokens": 100,
                "cache_read_input_tokens": 40,
                "output_tokens": 10,
                "total_tokens": 110
            }
        }))
        .expect("explicit usage");

        assert_eq!(usage["promptTokens"], 100);
        assert_eq!(usage["cachedInputTokens"], 40);
        assert_eq!(usage["completionTokens"], 10);
        assert_eq!(usage["totalTokens"], 110);
        assert_eq!(
            usage["promptTokens"].as_u64().unwrap() + usage["completionTokens"].as_u64().unwrap(),
            usage["totalTokens"].as_u64().unwrap()
        );
    }

    #[test]
    fn normalized_openagent_tokens_keep_additive_cache_and_reasoning() {
        let usage = extract_token_usage(&json!({
            "tokens": {
                "input": 60,
                "output": 5,
                "reasoning": 2,
                "cache": {"read": 30, "write": 10},
                "total": 67
            }
        }))
        .expect("normalized usage");

        assert_eq!(usage["promptTokens"], 100);
        assert_eq!(usage["cachedInputTokens"], 30);
        assert_eq!(usage["completionTokens"], 7);
        assert_eq!(usage["totalTokens"], 107);
    }

    #[test]
    fn parent_usage_marks_the_last_content_block_as_request_response_scope() {
        let messages = messages_from_json(
            HistoryAdapter::OpenCode,
            Path::new("fixture.json"),
            0,
            &json!({
                "role": "assistant",
                "content": [
                    {"type": "output_text", "text": "first"},
                    {"type": "output_text", "text": "second"},
                    {"type": "tool_use", "name": "read_fixture", "input": {}}
                ],
                "usage": {
                    "input_tokens": 100,
                    "cached_input_tokens": 40,
                    "output_tokens": 10,
                    "total_tokens": 110
                }
            }),
        );

        assert_eq!(messages.len(), 3);
        assert!(messages[0].get("usage").is_none());
        assert!(messages[1].get("usage").is_none());
        assert_eq!(messages[2]["cardType"], "tool-call");
        assert_eq!(messages[2]["usageScope"], "request-response");
        assert_eq!(messages[2]["usage"]["totalTokens"], 110);
    }

    #[test]
    fn opencode_adapter_imports_sqlite_message_parts() {
        let dir = temp_dir("opencode-sqlite-history");
        let database = dir.join("opencode.db");
        create_openagent_fixture_database(&database, "OpenCode prompt");

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "opencode");
        assert_eq!(sessions[0]["title"], "OpenCode prompt");
        assert_eq!(sessions[0]["model"], "gpt-test");
        assert_eq!(sessions[0]["workingDirectory"], "/workspace/opencode");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[0]["text"], "OpenCode prompt");
        assert_eq!(messages[1]["role"], "agent");
        assert_eq!(messages[1]["text"], "OpenCode answer");
    }

    #[test]
    fn kilo_code_adapter_imports_sqlite_message_parts() {
        let dir = temp_dir("kilo-sqlite-history");
        let database = dir.join("kilo.db");
        create_openagent_fixture_database(&database, "Kilo prompt");

        let listed = conversation_list(&json!({
            "agent": "kilo-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "kilo-code");
        assert_eq!(sessions[0]["title"], "Kilo prompt");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[0]["text"], "Kilo prompt");
        assert_eq!(messages[1]["role"], "agent");
    }

    #[test]
    fn openagent_sqlite_scan_does_not_truncate_after_one_thousand_sessions() {
        let dir = temp_dir("openagent-sqlite-unbounded-sessions");
        let database = dir.join("opencode.db");
        create_openagent_fixture_database(&database, "OpenCode prompt 0");
        let mut connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE INDEX message_session_id ON message(session_id);\
                 CREATE INDEX part_session_id ON part(session_id);",
            )
            .unwrap();
        let transaction = connection.transaction().unwrap();
        for index in 1..=1_000 {
            let session_id = format!("ses_{index:04}");
            let message_id = format!("msg_{index:04}");
            let prompt = format!("OpenCode prompt {index}");
            transaction
                .execute(
                    "INSERT INTO session VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                    (
                        &session_id,
                        &prompt,
                        "/workspace/opencode",
                        "/workspace/opencode",
                        "build",
                        "gpt-test",
                        1_787_616_000_000i64 + index,
                        1_787_616_060_000i64 + index,
                        1i64,
                        2i64,
                        0i64,
                        0i64,
                        0i64,
                    ),
                )
                .unwrap();
            transaction
                .execute(
                    "INSERT INTO message VALUES (?1, ?2, ?3, ?4, ?5)",
                    (
                        &message_id,
                        &session_id,
                        1_787_616_000_000i64 + index,
                        1_787_616_000_000i64 + index,
                        json!({
                            "role": "user",
                            "time": {"created": 1_787_616_000_000i64 + index},
                            "tokens": {"total": 3, "input": 1, "output": 2}
                        })
                        .to_string(),
                    ),
                )
                .unwrap();
            transaction
                .execute(
                    "INSERT INTO part VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    (
                        format!("part_{index:04}"),
                        &message_id,
                        &session_id,
                        1_787_616_000_000i64 + index,
                        1_787_616_000_000i64 + index,
                        json!({"type": "text", "text": prompt}).to_string(),
                    ),
                )
                .unwrap();
        }
        transaction.commit().unwrap();

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(listed["page"]["totalSessions"], 1_001);
        assert_eq!(listed["sessions"].as_array().unwrap().len(), 1_001);
    }

    #[test]
    fn copilot_adapter_imports_transcript_events() {
        let dir = temp_dir("copilot-transcript-history");
        let transcript_dir = dir.join("GitHub.copilot-chat/transcripts");
        fs::create_dir_all(&transcript_dir).unwrap();
        fs::write(
            transcript_dir.join("copilot-session.jsonl"),
            [
                r#"{"type":"session.start","data":{"sessionId":"copilot-session"},"timestamp":"2026-06-12T00:00:00Z"}"#,
                r#"{"type":"user.message","data":{"messageId":"u1","content":"Ask Copilot to inspect routing"},"timestamp":"2026-06-12T00:00:01Z"}"#,
                r#"{"type":"assistant.message","data":{"messageId":"a0","content":""},"timestamp":"2026-06-12T00:00:02Z"}"#,
                r#"{"type":"tool.execution_start","data":{"toolName":"readFile"},"timestamp":"2026-06-12T00:00:03Z"}"#,
                r#"{"type":"assistant.message","data":{"messageId":"a1","content":"Copilot answer"},"timestamp":"2026-06-12T00:00:04Z"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "copilot",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "copilot");
        assert_eq!(sessions[0]["nativeSessionId"], "copilot-session");
        assert_eq!(sessions[0]["title"], "Ask Copilot to inspect routing");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[1]["role"], "tool_call");
        assert_eq!(messages[1]["cardType"], "tool-call");
        assert_eq!(messages[1]["cardTitle"], "readFile");
        assert_eq!(messages[2]["role"], "agent");
    }

    fn create_openagent_fixture_database(path: &Path, prompt: &str) {
        let connection = Connection::open(path).unwrap();
        connection
            .execute(
                "CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    directory TEXT,
                    path TEXT,
                    agent TEXT,
                    model TEXT,
                    time_created INTEGER,
                    time_updated INTEGER,
                    tokens_input INTEGER,
                    tokens_output INTEGER,
                    tokens_reasoning INTEGER,
                    tokens_cache_read INTEGER,
                    tokens_cache_write INTEGER
                )",
                [],
            )
            .unwrap();
        connection
            .execute(
                "CREATE TABLE message (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    time_created INTEGER,
                    time_updated INTEGER,
                    data TEXT NOT NULL
                )",
                [],
            )
            .unwrap();
        connection
            .execute(
                "CREATE TABLE part (
                    id TEXT PRIMARY KEY,
                    message_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    time_created INTEGER,
                    time_updated INTEGER,
                    data TEXT NOT NULL
                )",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO session VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                (
                    "ses_fixture",
                    prompt,
                    "/workspace/opencode",
                    "/workspace/opencode",
                    "build",
                    "gpt-test",
                    1_787_616_000_000i64,
                    1_787_616_060_000i64,
                    10i64,
                    20i64,
                    0i64,
                    1i64,
                    2i64,
                ),
            )
            .unwrap();
        for (id, role, text, offset) in [
            ("msg_user", "user", prompt, 1_000i64),
            ("msg_agent", "assistant", "OpenCode answer", 2_000i64),
        ] {
            connection
                .execute(
                    "INSERT INTO message VALUES (?1, ?2, ?3, ?4, ?5)",
                    (
                        id,
                        "ses_fixture",
                        1_787_616_000_000i64 + offset,
                        1_787_616_000_000i64 + offset,
                        serde_json::to_string(&json!({
                            "role": role,
                            "time": {"created": 1_787_616_000_000i64 + offset},
                            "tokens": {"total": 3, "input": 1, "output": 2}
                        }))
                        .unwrap(),
                    ),
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO part VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    (
                        format!("part_{id}"),
                        id,
                        "ses_fixture",
                        1_787_616_000_000i64 + offset,
                        1_787_616_000_000i64 + offset,
                        serde_json::to_string(&json!({"type": "text", "text": text})).unwrap(),
                    ),
                )
                .unwrap();
        }
    }

    #[test]
    fn service_logs_with_embedded_messages_are_not_native_conversations() {
        let dir = temp_dir("embedded-message-log-history");
        fs::write(
            dir.join("opencode.log"),
            [
                r#"INFO 2026-06-20T00:00:00Z service=default directory=/repo/Pact creating instance"#,
                r#"ERROR 2026-06-20T00:00:01Z service=llm requestBodyValues={"messages":[{"role":"user","content":"Pact task"},{"role":"assistant","content":"answer"}]}"#,
                r#"INFO 2026-06-20T00:00:02Z service=server status=started"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy(),
            "archiveMode": true,
            "matchTerms": ["Pact"]
        }))
        .unwrap();

        assert_eq!(listed["sessions"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn text_transcripts_are_native_conversations() {
        let dir = temp_dir("text-transcript-history");
        fs::write(
            dir.join("conversation.txt"),
            ["User: archive the LicoLite history", "Assistant: archived"].join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["title"], "archive the LicoLite history");
    }

    #[test]
    fn codex_jsonl_groups_by_native_session_id() {
        let dir = temp_dir("codex-session-groups");
        fs::write(
            dir.join("session.jsonl"),
            [
                r#"{"sessionId":"codex-session-1","role":"user","content":"First session prompt"}"#,
                r#"{"sessionId":"codex-session-2","role":"user","content":"Second session prompt"}"#,
                r#"{"sessionId":"codex-session-2","role":"assistant","content":"Second session answer"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(listed["adapterId"], "codex");
        assert_eq!(listed["importMode"], "precise-adapter");
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 2);
        assert!(
            sessions
                .iter()
                .any(|session| session["nativeSessionId"] == "codex-session-2"
                    && session["messages"].as_array().unwrap().len() == 2)
        );

        let native_filtered = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "sessionId": "codex-session-2"
        }))
        .unwrap();
        let native_sessions = native_filtered["sessions"].as_array().unwrap();
        assert_eq!(native_sessions.len(), 1);
        assert_eq!(native_sessions[0]["nativeSessionId"], "codex-session-2");

        let projection_id = native_sessions[0]["id"].as_str().unwrap();
        let projection_filtered = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "sessionId": projection_id
        }))
        .unwrap();
        assert_eq!(projection_filtered["sessions"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn conversations_list_paginates_native_history_sessions() {
        let dir = temp_dir("codex-history-pagination");
        let lines = (0..120)
            .map(|index| {
                format!(
                    r#"{{"sessionId":"page-session-{index}","role":"user","content":"Paged history prompt {index}","createdAt":{}}}"#,
                    1_787_616_000_000i64 + index * 1000
                )
            })
            .collect::<Vec<_>>();
        fs::write(dir.join("history.jsonl"), lines.join("\n")).unwrap();

        let page_two = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "limit": 50,
            "offset": 50
        }))
        .unwrap();
        let sessions = page_two["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 50);
        assert_eq!(sessions[0]["nativeSessionId"], "page-session-69");
        assert_eq!(page_two["page"]["offset"], 50);
        assert_eq!(page_two["page"]["limit"], 50);
        assert_eq!(page_two["page"]["totalSessions"], 120);
        assert_eq!(page_two["page"]["hasMore"], true);

        let last_page = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "limit": 50,
            "offset": 100
        }))
        .unwrap();
        assert_eq!(last_page["sessions"].as_array().unwrap().len(), 20);
        assert_eq!(last_page["page"]["hasMore"], false);
    }

    #[test]
    fn codex_exact_session_readback_parses_only_the_bound_rollout() {
        let home = temp_dir("codex-exact-readback");
        let sessions = home.join(".codex").join("sessions").join("2026/07/14");
        fs::create_dir_all(&sessions).unwrap();
        let session_id = "019e8d1d-fb25-7d82-b849-80a87fbe407d";
        for index in 0..64 {
            fs::write(
                sessions.join(format!("rollout-unrelated-{index:03}.jsonl")),
                "not-json",
            )
            .unwrap();
        }
        fs::write(
            sessions.join(format!("rollout-2026-07-14T00-00-00-{session_id}.jsonl")),
            [
                format!(
                    r#"{{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{{"id":"{session_id}","cwd":"/workspace/project"}}}}"#
                ),
                r#"{"timestamp":"2026-07-14T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Exact readback prompt"}]}}"#.to_string(),
                r#"{"timestamp":"2026-07-14T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Exact readback reply"}]}}"#.to_string(),
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            home.join(".codex").join("session_index.jsonl"),
            format!(r#"{{"id":"{session_id}","thread_name":"index-title-must-not-be-read"}}"#),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "homeDir": home.to_string_lossy(),
            "sessionId": session_id,
            "limit": 1
        }))
        .unwrap();

        assert_eq!(listed["sources"]["filesSeen"], 1);
        assert!(listed["sources"]["directoryEntriesSeen"].as_u64().unwrap() < 128);
        let found = listed["sessions"].as_array().unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0]["nativeSessionId"], session_id);
        assert_eq!(found[0]["messages"].as_array().unwrap().len(), 2);
        assert_ne!(found[0]["title"], "index-title-must-not-be-read");
    }

    #[test]
    fn exact_history_scan_stops_at_the_global_directory_entry_bound() {
        let root = temp_dir("codex-directory-entry-bound");
        fs::write(root.join("rollout-bound.jsonl"), "not-json").unwrap();
        let config = HistoryScanConfig::from_params(&json!({
            "sessionId": "bound"
        }));
        let mut projected = Vec::new();
        let mut skipped = Vec::new();
        let mut files_seen = 0usize;
        let mut directory_entries_seen = MAX_HISTORY_DIRECTORY_ENTRIES;
        scan_history_path(
            HistoryAdapter::Codex,
            &root,
            "codex-session-store",
            config,
            &mut projected,
            &mut skipped,
            &mut files_seen,
            &mut directory_entries_seen,
            0,
        );
        assert!(projected.is_empty());
        assert_eq!(files_seen, 0);
        assert!(skipped.iter().any(|entry| {
            entry.get("reason").and_then(Value::as_str) == Some("directory_entry_limit_reached")
        }));
    }

    #[test]
    fn codex_adapter_extracts_rollout_payload_sessions() {
        let dir = temp_dir("codex-rollout");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-06-03T18-53-32-019e8d1d-fb25-7d82-b849-80a87fbe407d.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-06-03T10:53:36.044Z","type":"session_meta","payload":{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d","cwd":"/workspace/projects/pact","originator":"codex","cli_version":"1.2.3"}}"#,
                r#"{"timestamp":"2026-06-03T10:53:43.745Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Continue Pact archive work"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Archive implementation answer"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:52.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Checked the archive plan at /workspace/projects/pact with authorization=Bearer abcdefghijklmnopqrstuvwxyz0123456789"}],"text":"Private chain of thought"}}"#,
                r#"{"timestamp":"2026-06-03T10:53:55.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"rg Pact /workspace/projects/pact\",\"access_token\":\"secret-value\"}"}}"#,
                r#"{"timestamp":"2026-06-03T10:53:56.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"path\":\"/workspace/projects/pact\",\"access_token\":\"secret-value\",\"ok\":true}"}}"#,
                r#"{"timestamp":"2026-06-03T10:53:57.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"Command failed in /workspace/projects/pact with authorization=Bearer abcdefghijklmnopqrstuvwxyz0123456789"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "archiveMode": true
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        let session = &sessions[0];
        assert_eq!(session["adapterId"], "codex");
        assert_eq!(
            session["nativeSessionId"],
            "019e8d1d-fb25-7d82-b849-80a87fbe407d"
        );
        assert_eq!(session["workingDirectory"], "/workspace/projects/pact");
        let messages = session["messages"].as_array().unwrap();
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains("/workspace/projects/pact")
        }));
        assert!(
            messages
                .iter()
                .any(|message| message["text"] == "Continue Pact archive work")
        );
        assert!(messages.iter().any(|message| message["role"] == "agent"));
        let reasoning = messages
            .iter()
            .find(|message| message["role"] == "reasoning")
            .expect("reasoning card");
        assert_eq!(reasoning["cardType"], "reasoning");
        assert_eq!(reasoning["collapsed"], true);
        assert_eq!(reasoning["providerSummary"], true);
        assert_eq!(reasoning["cardSubtitle"], "Reasoning summary");
        assert_eq!(
            reasoning["text"],
            "Checked the archive plan at [local path hidden] with authorization: [redacted] [redacted]"
        );
        let tool_call = messages
            .iter()
            .find(|message| message["role"] == "tool_call")
            .expect("tool call card");
        assert_eq!(tool_call["cardType"], "tool-call");
        assert_eq!(tool_call["cardTitle"], "exec_command");
        let tool_result = messages
            .iter()
            .find(|message| message["role"] == "tool_result")
            .expect("tool result card");
        assert_eq!(tool_result["cardType"], "tool-result");
        assert_eq!(tool_result["text"], "The native tool result was recorded.");
        let error = messages
            .iter()
            .find(|message| message["role"] == "error")
            .expect("error card");
        assert_eq!(error["cardType"], "error");
        assert_eq!(error["collapsed"], false);
        let serialized = serde_json::to_string(messages).unwrap();
        assert!(!serialized.contains("Private chain of thought"));
        assert!(!serialized.contains("secret-value"));
        assert!(!serialized.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains("/workspace/projects/pact")
        }));
    }

    #[test]
    fn codex_adapter_skips_local_command_caveats_for_titles() {
        let dir = temp_dir("codex-readable-title");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-06-03T18-53-32-019e8d1d-fb25-7d82-b849-80a87fbe407d.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-06-03T10:53:36.044Z","type":"session_meta","payload":{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d","cwd":"/workspace/projects/pact"}}"#,
                r#"{"timestamp":"2026-06-03T10:53:43.745Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<local-command-caveat>Caveat: generated command context. DO NOT respond to these messages.</local-command-caveat>"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:44.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain readable Codex history titles"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Readable title answer"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let session = &listed["sessions"].as_array().unwrap()[0];
        assert_eq!(session["title"], "Explain readable Codex history titles");
        let messages = session["messages"].as_array().unwrap();
        assert!(messages.iter().any(|message| {
            message["text"] == "Explain readable Codex history titles" && message["role"] == "user"
        }));
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains("<local-command-caveat>")
        }));
    }

    #[test]
    fn codex_session_index_thread_name_wins_over_message_noise() {
        let dir = temp_dir("codex-session-index-title");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-07-12T00-00-00-019e8d1d-fb25-7d82-b849-80a87fbe407d.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-07-12T00:00:00.000Z","type":"session_meta","payload":{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d","cwd":"/workspace/projects/lico"}}"#,
                r#"{"timestamp":"2026-07-12T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<recommended_plugins> Here is a list of plugins that are available...</recommended_plugins>"}]}}"#,
                r#"{"timestamp":"2026-07-12T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Check the release base"}]}}"#,
                r#"{"timestamp":"2026-07-12T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            dir.join("session_index.jsonl"),
            r#"{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d","thread_name":"检查发布基座","updated_at":"2026-07-12T00:04:00.000Z"}
"#,
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(
            sessions.len(),
            1,
            "listed={}",
            serde_json::to_string_pretty(&listed).unwrap()
        );
        assert_eq!(sessions[0]["title"], "检查发布基座");
        assert_eq!(
            sessions[0]["nativeSessionId"],
            "019e8d1d-fb25-7d82-b849-80a87fbe407d"
        );
    }

    #[test]
    fn native_history_ignores_command_tags_and_status_titles() {
        let dir = temp_dir("native-title-noise");
        fs::write(
            dir.join("project.json"),
            r#"{
              "title": "Updated 1 path from the index",
              "sessions": [
                {
                  "sessionId": "clear-command",
                  "messages": [
                    {"role": "user", "content": "<command-name>/clear</command-name><command-message>The conversation has been cleared.</command-message>"},
                    {"role": "assistant", "content": "The conversation has been cleared. What would you like to do next?"}
                  ]
                },
                {
                  "sessionId": "real-request",
                  "title": "Updated 1 path from the index",
                  "messages": [
                    {"role": "user", "content": "Fix readable conversation titles"},
                    {"role": "assistant", "content": "Readable title answer"}
                  ]
                }
              ]
            }"#,
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], "real-request");
        assert_eq!(sessions[0]["title"], "Fix readable conversation titles");
        assert!(
            !sessions[0]["messages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|message| {
                    message["text"]
                        .as_str()
                        .unwrap_or_default()
                        .contains("<command-name>")
                })
        );
    }

    #[test]
    fn antigravity_history_decodes_protocol_wrapped_messages() {
        let dir = temp_dir("antigravity-protocol-history");
        fs::write(
            dir.join("ag-session.json"),
            serde_json::to_string_pretty(&json!({
                "sessions": [
                    {
                        "sessionId": "antigravity-session",
                        "title": "<USER_REQUEST> 请找到本项目的开发规则文档入口 </USER_REQUEST>",
                        "messages": [
                            {
                                "role": "user",
                                "content": "<SYSTEM_MESSAGE>Hidden Antigravity runtime context.</SYSTEM_MESSAGE>\n<USER_REQUEST>请找到本项目的开发规则文档入口</USER_REQUEST>"
                            },
                            {
                                "role": "assistant",
                                "content": "The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to."
                            },
                            {
                                "role": "view_file",
                                "content": "2255 │ \"coverageContribution\": false,\n2256 │ \"artifacts\": [],\n2257 │ \"command\": \"npm\"\n2258 │ \"args\": [\n2259 │   \"run\",\n2260 │   \"verify\"\n2261 │ ]"
                            },
                            {
                                "role": "run_command",
                                "content": "npm run verify\nPASS 133 tests"
                            },
                            {
                                "role": "planner_response",
                                "content": "开发规则入口在仓库根目录的 AGENTS.md。"
                            }
                        ]
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "antigravity",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["title"], "请找到本项目的开发规则文档入口");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 4);
        assert_eq!(messages[0]["text"], "请找到本项目的开发规则文档入口");
        assert_eq!(messages[1]["role"], "tool_call");
        assert_eq!(messages[1]["cardTitle"], "View file");
        assert_eq!(messages[2]["role"], "tool_call");
        assert_eq!(messages[2]["cardTitle"], "Run command");
        assert_eq!(
            messages[3]["text"],
            "开发规则入口在仓库根目录的 AGENTS.md。"
        );
        assert!(!messages.iter().any(|message| {
            let text = message["text"].as_str().unwrap_or_default();
            text.contains("<USER_REQUEST>")
                || text.contains("<SYSTEM_MESSAGE>")
                || text.contains("not actually sent by the user")
                || text.contains("coverageContribution")
                || text.contains("npm run verify")
                || text.contains("2255")
        }));
    }

    #[test]
    fn native_history_merges_delegated_subagent_prompt_sessions() {
        let dir = temp_dir("native-subagent-prompt");
        fs::write(
            dir.join("project.jsonl"),
            [
                r#"{"timestamp":"2026-06-01T00:00:00Z","sessionId":"real-session","type":"user","message":{"role":"user","content":"Why are history titles unreadable?"}}"#,
                r#"{"timestamp":"2026-06-01T00:00:01Z","sessionId":"subagent-session","type":"user","message":{"role":"user","content":"You are A1: Old-path Migration Batch. Inspect the repository and report."}}"#,
                r#"{"timestamp":"2026-06-01T00:00:02Z","sessionId":"subagent-session","type":"assistant","message":{"role":"assistant","content":"I need to find old-path files in the LicoLite repo."}}"#,
                r#"{"timestamp":"2026-06-01T00:00:03Z","sessionId":"real-session","type":"assistant","message":{"role":"assistant","content":"I will fix the title extraction."}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], "real-session");
        assert_eq!(sessions[0]["title"], "Why are history titles unreadable?");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[1]["role"], "subagent");
        assert_eq!(messages[1]["cardType"], "subagent");
        assert_eq!(messages[1]["cardTitle"], "A1: Old-path Migration Batch");
        assert_eq!(
            messages[1]["messages"][0]["text"],
            "I need to find old-path files in the LicoLite repo."
        );
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains("You are A1")
        }));
        assert!(looks_like_delegated_agent_prompt(
            "You are discovery worker round-05/worker-03 for a Codex Security Deep Security Scan. You are not the coordinator."
        ));
    }

    #[test]
    fn codex_history_merges_explicit_subagent_lineage_into_parent_thread() {
        let dir = temp_dir("codex-explicit-subagent-lineage");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::write(
            sessions.join("rollout-parent.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T00:00:00Z","type":"session_meta","payload":{"id":"parent-session","cwd":"/workspace/project"}}"#,
                r#"{"timestamp":"2026-07-12T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Audit this page"}]}}"#,
                r#"{"timestamp":"2026-07-12T00:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Merged the worker result."}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            sessions.join("rollout-child.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T00:00:02Z","type":"session_meta","payload":{"id":"child-session","cwd":"/workspace/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","agent_nickname":"reviewer"}}}}}"#,
                r#"{"timestamp":"2026-07-12T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found one issue."}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], "parent-session");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[1]["role"], "subagent");
        assert_eq!(messages[1]["cardTitle"], "reviewer");
        assert_eq!(messages[1]["messages"][0]["text"], "Found one issue.");
    }

    #[test]
    fn codex_history_merges_forked_rollout_continuations_by_lineage() {
        let dir = temp_dir("codex-fork-lineage-merge");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::write(
            sessions.join("rollout-root.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T01:00:00Z","type":"session_meta","payload":{"id":"root-session","cwd":"/workspace/project"}}"#,
                r#"{"timestamp":"2026-07-12T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
                r#"{"timestamp":"2026-07-12T01:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            sessions.join("rollout-fork-a.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T02:00:00Z","type":"session_meta","payload":{"id":"fork-a","cwd":"/workspace/project","forked_from_id":"root-session"}}"#,
                r#"{"timestamp":"2026-07-12T02:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
                r#"{"timestamp":"2026-07-12T02:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
                r#"{"timestamp":"2026-07-12T02:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续第二轮"}]}}"#,
                r#"{"timestamp":"2026-07-12T02:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第二轮完成"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            sessions.join("rollout-fork-b.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T03:00:00Z","type":"session_meta","payload":{"id":"fork-b","cwd":"/workspace/project","forked_from_id":"fork-a"}}"#,
                r#"{"timestamp":"2026-07-12T03:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
                r#"{"timestamp":"2026-07-12T03:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
                r#"{"timestamp":"2026-07-12T03:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续第二轮"}]}}"#,
                r#"{"timestamp":"2026-07-12T03:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第二轮完成"}]}}"#,
                r#"{"timestamp":"2026-07-12T03:00:05Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"再继续第三轮"}]}}"#,
                r#"{"timestamp":"2026-07-12T03:00:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第三轮完成"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(
            sessions.join("rollout-unrelated.jsonl"),
            [
                r#"{"timestamp":"2026-07-12T04:00:00Z","type":"session_meta","payload":{"id":"unrelated-session","cwd":"/workspace/project"}}"#,
                r#"{"timestamp":"2026-07-12T04:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
                r#"{"timestamp":"2026-07-12T04:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"这是无关会话"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 2);
        let lineage = sessions
            .iter()
            .find(|session| session["lineageRootId"] == "root-session")
            .expect("lineage session");
        assert_eq!(lineage["nativeSessionId"], "fork-b");
        assert_eq!(lineage["lineageRootId"], "root-session");
        let lineage_ids = lineage["lineageSessionIds"].as_array().unwrap();
        assert_eq!(lineage_ids.len(), 3);
        assert!(lineage_ids.iter().any(|value| value == "root-session"));
        assert!(lineage_ids.iter().any(|value| value == "fork-a"));
        assert!(lineage_ids.iter().any(|value| value == "fork-b"));
        let texts = lineage["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|message| message.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>();
        assert!(texts.contains(&"第三轮完成"));
        assert_eq!(
            texts
                .iter()
                .filter(|text| **text == "请验收当前 Lico Arc 客户端")
                .count(),
            1
        );
        let unrelated = sessions
            .iter()
            .find(|session| session["nativeSessionId"] == "unrelated-session")
            .expect("unrelated session");
        assert_eq!(unrelated["title"], "请验收当前 Lico Arc 客户端");
    }

    #[test]
    fn codex_history_dedupes_same_native_session_across_active_and_archive_paths() {
        let dir = temp_dir("codex-active-archive-dedupe");
        let active = dir.join("sessions");
        let archived = dir.join("archived_sessions");
        fs::create_dir_all(&active).unwrap();
        fs::create_dir_all(&archived).unwrap();
        let body = [
            r#"{"timestamp":"2026-07-12T05:00:00Z","type":"session_meta","payload":{"id":"shared-session","cwd":"/workspace/project"}}"#,
            r#"{"timestamp":"2026-07-12T05:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Same thread"}]}}"#,
            r#"{"timestamp":"2026-07-12T05:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Same reply"}]}}"#,
        ]
        .join("\n");
        fs::write(active.join("rollout-shared.jsonl"), &body).unwrap();
        fs::write(archived.join("rollout-shared.jsonl"), &body).unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], "shared-session");
    }

    #[test]
    fn codex_adapter_skips_background_context_prompt_messages() {
        let dir = temp_dir("codex-background-context");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-06-03T18-53-32-019e8d1d-fb25-7d82-b849-80a87fbe407d.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-06-03T10:53:36.044Z","type":"session_meta","payload":{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d","cwd":"/workspace/projects/pact"}}"#,
                r##"{"timestamp":"2026-06-03T10:53:43.745Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n\n<INSTRUCTIONS>\n1. Background repo rule.\n</INSTRUCTIONS>\n<environment_context>\n  <cwd>fixture-workspace</cwd>\n</environment_context>"}]}}"##,
                r#"{"timestamp":"2026-06-03T10:53:44.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Show only the user request"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Only the request is shown"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let session = &listed["sessions"].as_array().unwrap()[0];
        assert_eq!(session["title"], "Show only the user request");
        let messages = session["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert!(messages.iter().any(|message| {
            message["role"] == "user" && message["text"] == "Show only the user request"
        }));
        assert!(!messages.iter().any(|message| {
            let text = message["text"].as_str().unwrap_or_default();
            text.contains("AGENTS.md")
                || text.contains("Background repo rule")
                || text.contains("<environment_context>")
                || text.contains("fixture-workspace")
        }));
    }

    #[test]
    fn codex_adapter_skips_apps_instructions_prompt_messages() {
        let dir = temp_dir("codex-apps-instructions-context");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-06-03T18-53-32-019e8d1d-fb25-7d82-b849-apps.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-06-03T10:53:43.745Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<apps_instructions>\n# Apps (Connectors)\nApps can be explicitly triggered.\n</appsinstructions>"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:44.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"真正的用户问题"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:53:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"真正的回答"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let session = &listed["sessions"].as_array().unwrap()[0];
        assert_eq!(session["title"], "真正的用户问题");
        let messages = session["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert!(messages.iter().any(|message| {
            message["role"] == "user" && message["text"] == "真正的用户问题"
        }));
        assert!(!messages.iter().any(|message| {
            let text = message["text"].as_str().unwrap_or_default();
            text.contains("Apps (Connectors)") || text.contains("<apps_instructions>")
        }));
    }

    #[test]
    fn codex_adapter_extracts_real_user_request_from_app_wrapper() {
        let dir = temp_dir("codex-user-wrapper");
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        let rollout =
            sessions.join("rollout-2026-06-03T18-53-32-019e8d1d-fb25-7d82-b849-80a87fbe407d.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-06-03T10:53:36.044Z","type":"session_meta","payload":{"id":"019e8d1d-fb25-7d82-b849-80a87fbe407d"}}"#,
                r##"{"timestamp":"2026-06-03T10:53:44.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Files mentioned by the user:\n\n## codex-clipboard.png: fixture/codex-clipboard.png\n\n## My request for Codex:\n对话需要支持 Markdown 渲染\n<image name=[Image #1] path=\"fixture/codex-clipboard.png\">\nprivate image metadata\n</image>"}]}}"##,
                r#"{"timestamp":"2026-06-03T10:53:50.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Markdown rendered"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let session = &listed["sessions"].as_array().unwrap()[0];
        let messages = session["messages"].as_array().unwrap();
        assert!(messages.iter().any(|message| {
            message["role"] == "user" && message["text"] == "对话需要支持 Markdown 渲染"
        }));
        assert!(!messages.iter().any(|message| {
            let text = message["text"].as_str().unwrap_or_default();
            text.contains("Files mentioned")
                || text.contains("codex-clipboard")
                || text.contains("<image")
                || text.contains("private image metadata")
        }));
    }

    #[test]
    fn claude_code_adapter_extracts_nested_jsonl_messages() {
        let dir = temp_dir("claude-history");
        fs::write(
            dir.join("project.jsonl"),
            [
                r#"{"sessionId":"claude-session-1","type":"user","message":{"role":"user","content":[{"type":"text","text":"Open the LicoLite repo"}]}}"#,
                r#"{"sessionId":"claude-session-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Repo opened"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "claude-code");
        assert_eq!(sessions[0]["nativeSessionId"], "claude-session-1");
        assert_eq!(sessions[0]["messages"][0]["text"], "Open the LicoLite repo");
        assert_eq!(sessions[0]["messages"][1]["role"], "agent");
    }

    #[test]
    fn claude_code_adapter_preserves_mixed_text_and_tool_use_blocks() {
        let dir = temp_dir("claude-mixed-content-history");
        let path_canary = ["fixture", "source.rs"].join("/");
        let credential_canary = ["fixture", "credential", "canary"].join("-");
        fs::write(
            dir.join("project.jsonl"),
            [
                json!({
                    "sessionId": "claude-session-1",
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": "Inspect the current implementation"}]
                    }
                })
                .to_string(),
                json!({
                    "sessionId": "claude-session-1",
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": "I will inspect it."},
                            {
                                "type": "tool_use",
                                "id": "toolu_1",
                                "name": "Read",
                                "input": {
                                    "file_path": path_canary.clone(),
                                    "access_token": credential_canary.clone()
                                }
                            },
                            {"type": "text", "text": "Inspection complete."}
                        ]
                    }
                })
                .to_string(),
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let messages = listed["sessions"][0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 4);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[1]["text"], "I will inspect it.");
        assert_eq!(messages[2]["role"], "tool_call");
        assert_eq!(messages[2]["cardType"], "tool-call");
        assert_eq!(messages[2]["cardTitle"], "Read");
        assert_eq!(messages[3]["text"], "Inspection complete.");
        let serialized = serde_json::to_string(messages).unwrap();
        assert!(!serialized.contains(&credential_canary));
        assert!(!serialized.contains(&path_canary));
    }

    #[test]
    fn claude_code_adapter_preserves_tool_result_as_redacted_event() {
        let dir = temp_dir("claude-tool-result-history");
        fs::write(
            dir.join("project.jsonl"),
            [
                r#"{"sessionId":"claude-session-1","type":"user","message":{"role":"user","content":[{"type":"text","text":"为什么这个对话上下文这么长？"}]}}"#,
                r#"{"sessionId":"claude-session-1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"{\n  \"id\": \"client.linux.smoke\",\n  \"owner\": \"client\",\n  \"package\": \"client\",\n  \"requiredServices\": [],\n  \"profiles\": [\"external\"]\n}"}]}}"#,
                r#"{"sessionId":"claude-session-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"这是工具返回的配置，不应该作为正文展示。"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["title"], "为什么这个对话上下文这么长？");
        let messages = sessions[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0]["text"], "为什么这个对话上下文这么长？");
        assert_eq!(messages[1]["role"], "tool_result");
        assert_eq!(messages[1]["cardType"], "tool-result");
        assert_eq!(messages[1]["collapsed"], true);
        assert_eq!(messages[1]["text"], "The native tool result was recorded.");
        assert_eq!(messages[2]["role"], "agent");
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains("client.linux.smoke")
        }));
    }

    #[test]
    fn native_history_preserves_metadata_error_and_unknown_event_semantics() {
        let dir = temp_dir("native-structured-events");
        let path_canary = ["fixture", "project"].join("/");
        let credential_canary = ["fixture", "credential", "canary"].join("-");
        fs::write(
            dir.join("project.jsonl"),
            [
                json!({
                    "sessionId": "structured-session",
                    "role": "user",
                    "content": "Run the native operation"
                })
                .to_string(),
                json!({
                    "sessionId": "structured-session",
                    "role": "metadata",
                    "content": json!({
                        "cwd": path_canary.clone(),
                        "access_token": credential_canary.clone()
                    })
                    .to_string()
                })
                .to_string(),
                json!({
                    "sessionId": "structured-session",
                    "role": "error",
                    "content": format!(
                        "Operation failed under {path_canary} with credential={credential_canary}"
                    )
                })
                .to_string(),
                json!({
                    "sessionId": "structured-session",
                    "role": "lifecycle_notice",
                    "content": "Native operation entered cleanup."
                })
                .to_string(),
                json!({
                    "sessionId": "structured-session",
                    "role": "assistant",
                    "content": "Cleanup completed."
                })
                .to_string(),
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let messages = listed["sessions"][0]["messages"].as_array().unwrap();
        let roles = messages
            .iter()
            .map(|message| message["role"].as_str().unwrap_or_default())
            .collect::<Vec<_>>();
        assert_eq!(roles, vec!["user", "metadata", "error", "event", "agent"]);
        assert_eq!(messages[1]["role"], "metadata");
        assert_eq!(messages[1]["cardType"], "metadata");
        assert_eq!(messages[1]["collapsed"], true);
        assert_eq!(messages[1]["text"], "Sensitive native metadata is hidden.");
        assert_eq!(messages[2]["role"], "error");
        assert_eq!(messages[2]["cardType"], "error");
        assert_eq!(messages[2]["collapsed"], false);
        assert_eq!(messages[3]["role"], "event");
        assert_eq!(messages[3]["cardType"], "event");
        assert_eq!(messages[4]["role"], "agent");
        let serialized = serde_json::to_string(messages).unwrap();
        assert!(!serialized.contains(&credential_canary));
        assert!(!messages.iter().any(|message| {
            message["text"]
                .as_str()
                .unwrap_or_default()
                .contains(&path_canary)
        }));
    }

    #[test]
    fn native_history_decodes_embedded_json_string_content() {
        let dir = temp_dir("decoded-embedded-history");
        fs::write(
            dir.join("project.jsonl"),
            [
                r#"{"sessionId":"claude-session-1","type":"user","message":{"role":"user","content":"{\"type\":\"text\",\"text\":\"Decoded native prompt title\"}"}}"#,
                r#"{"sessionId":"claude-session-1","type":"assistant","message":{"role":"assistant","content":"{\"type\":\"text\",\"text\":\"Decoded native answer\"}"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "claude-code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let session = &listed["sessions"].as_array().unwrap()[0];
        assert_eq!(session["title"], "Decoded native prompt title");
        assert_eq!(
            session["messages"][0]["text"],
            "Decoded native prompt title"
        );
        assert_eq!(session["messages"][1]["text"], "Decoded native answer");
    }

    #[test]
    fn cursor_adapter_reads_sqlite_blob_chat_payloads() {
        let dir = temp_dir("cursor-history");
        let database = dir.join("state.vscdb");
        {
            let connection = Connection::open(&database).unwrap();
            connection
                .execute(
                    "CREATE TABLE ItemTable (key TEXT NOT NULL, value BLOB NOT NULL)",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                    (
                        "composerData.session-1",
                        br#"{"messages":[{"role":"user","text":"Cursor native prompt"},{"role":"assistant","text":"Cursor native answer"}]}"#.as_slice(),
                    ),
                )
                .unwrap();
        }

        let listed = conversation_list(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "cursor");
        assert_eq!(sessions[0]["nativeSessionId"], "composerData.session-1");
        assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn cursor_adapter_reads_disk_kv_composer_bubbles_with_model() {
        let dir = temp_dir("cursor-disk-kv");
        let database = dir.join("state.vscdb");
        let composer_id = "11111111-1111-1111-1111-111111111111";
        let user_bubble = "22222222-2222-2222-2222-222222222222";
        let agent_bubble = "33333333-3333-3333-3333-333333333333";
        {
            let connection = Connection::open(&database).unwrap();
            connection
                .execute(
                    "CREATE TABLE cursorDiskKV (key TEXT NOT NULL, value BLOB NOT NULL)",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("composerData:{composer_id}"),
                        serde_json::to_vec(&json!({
                            "composerId": composer_id,
                            "name": "Cursor model session",
                            "createdAt": 1_773_798_000_000i64,
                            "lastUpdatedAt": 1_773_798_100_000i64,
                            "modelConfig": { "modelName": "default", "maxMode": false },
                            "fullConversationHeadersOnly": [
                                { "bubbleId": user_bubble, "type": 1 },
                                { "bubbleId": agent_bubble, "type": 2 }
                            ]
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("bubbleId:{composer_id}:{user_bubble}"),
                        serde_json::to_vec(&json!({
                            "bubbleId": user_bubble,
                            "type": 1,
                            "createdAt": 1_773_798_000_000i64,
                            "text": "Please review this Cursor usage scan.",
                            "tokenCount": { "inputTokens": 0, "outputTokens": 0 }
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("bubbleId:{composer_id}:{agent_bubble}"),
                        serde_json::to_vec(&json!({
                            "bubbleId": agent_bubble,
                            "type": 2,
                            "createdAt": 1_773_798_050_000i64,
                            "text": "Cursor attributed this reply to the selected model.",
                            "modelInfo": { "modelName": "grok-4.5" },
                            "tokenCount": { "inputTokens": 120, "outputTokens": 40 }
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
        }

        let listed = conversation_list(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy()
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], composer_id);
        assert_eq!(sessions[0]["model"], "cursor-auto");
        assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
        assert_eq!(sessions[0]["messages"][0]["role"], "user");
        assert_eq!(sessions[0]["messages"][0]["model"], "cursor-auto");
        assert_eq!(sessions[0]["messages"][1]["role"], "agent");
        assert_eq!(sessions[0]["messages"][1]["model"], "grok-4.5");
        assert_eq!(sessions[0]["messages"][1]["usage"]["promptTokens"], 120);
        assert_eq!(sessions[0]["messages"][1]["usage"]["completionTokens"], 40);

        let usage = crate::domain::agent_usage::scan(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy(),
            "historyDays": 3650,
            "forceRefresh": true,
            "allowancesOnly": false,
            "stateRoot": temp_dir("cursor-usage-state").to_string_lossy()
        }))
        .unwrap();
        let history = &usage["agents"][0]["history"];
        let daily = history["dailyUsage"].as_array().unwrap();
        assert!(!daily.is_empty(), "expected cursor daily usage entries");
        let model_usage = daily[0]["modelUsage"].as_object().unwrap();
        assert!(
            model_usage.contains_key("grok-4.5"),
            "expected grok-4.5 model usage, got {model_usage:?}"
        );
        assert!(
            !model_usage.contains_key("Others"),
            "cursor models should not collapse into Others: {model_usage:?}"
        );
    }

    #[test]
    fn cursor_adapter_prefers_selected_models_over_composer_label() {
        let dir = temp_dir("cursor-selected-models");
        let database = dir.join("state.vscdb");
        let composer_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        let user_bubble = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        let agent_bubble = "cccccccc-cccc-cccc-cccc-cccccccccccc";
        {
            let connection = Connection::open(&database).unwrap();
            connection
                .execute(
                    "CREATE TABLE cursorDiskKV (key TEXT NOT NULL, value BLOB NOT NULL)",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("composerData:{composer_id}"),
                        serde_json::to_vec(&json!({
                            "composerId": composer_id,
                            "name": "Composer label hides selected model",
                            "createdAt": 1_773_798_000_000i64,
                            "lastUpdatedAt": 1_773_798_100_000i64,
                            "modelConfig": {
                                "modelName": "composer-2.5-fast",
                                "maxMode": false,
                                "selectedModels": [{ "modelId": "grok-4.5", "parameters": [] }]
                            },
                            "fullConversationHeadersOnly": [
                                { "bubbleId": user_bubble, "type": 1 },
                                { "bubbleId": agent_bubble, "type": 2 }
                            ]
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("bubbleId:{composer_id}:{user_bubble}"),
                        serde_json::to_vec(&json!({
                            "bubbleId": user_bubble,
                            "type": 1,
                            "createdAt": 1_773_798_000_000i64,
                            "text": "Attribute Cursor usage to the selected model.",
                            "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
                            "modelInfo": { "modelName": "default" }
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                    rusqlite::params![
                        format!("bubbleId:{composer_id}:{agent_bubble}"),
                        serde_json::to_vec(&json!({
                            "bubbleId": agent_bubble,
                            "type": 2,
                            "createdAt": 1_773_798_050_000i64,
                            "text": "Selected model should win over Composer product label.",
                            "tokenCount": { "inputTokens": 80, "outputTokens": 20 },
                            "modelInfo": { "modelName": "default" }
                        }))
                        .unwrap()
                    ],
                )
                .unwrap();
        }

        let listed = conversation_list(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy()
        }))
        .unwrap();
        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["model"], "grok-4.5");
        assert_eq!(sessions[0]["messages"][0]["model"], "grok-4.5");
        assert_eq!(sessions[0]["messages"][1]["model"], "grok-4.5");

        let usage = crate::domain::agent_usage::scan(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy(),
            "historyDays": 3650,
            "forceRefresh": true,
            "allowancesOnly": false,
            "stateRoot": temp_dir("cursor-selected-usage-state").to_string_lossy()
        }))
        .unwrap();
        let model_usage = usage["agents"][0]["history"]["dailyUsage"][0]["modelUsage"]
            .as_object()
            .unwrap();
        assert_eq!(model_usage.get("grok-4.5"), Some(&json!(100)));
        assert!(
            !model_usage.contains_key("composer-2.5-fast"),
            "composer product label must not replace selected model: {model_usage:?}"
        );
        assert!(
            !model_usage.contains_key("Others"),
            "cursor selected models must not collapse into Others: {model_usage:?}"
        );
        assert!(
            !model_usage.contains_key("cursor-auto"),
            "bubble modelInfo default must fall back to selected model: {model_usage:?}"
        );
    }

    #[test]
    fn copilot_adapter_imports_item_table_chat_sessions() {
        let dir = temp_dir("copilot-history");
        let database = dir.join("state.vscdb");
        {
            let connection = Connection::open(&database).unwrap();
            connection
                .execute(
                    "CREATE TABLE ItemTable (key TEXT NOT NULL, value TEXT NOT NULL)",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                    [
                        "github.copilot-chat.chatSessions",
                        r#"{"chatSessions":[{"id":"copilot-chat-1","messages":[{"role":"user","content":"Ask Copilot about LicoLite"},{"role":"assistant","content":"Copilot answer"}]}]}"#,
                    ],
                )
                .unwrap();
        }

        let listed = conversation_list(&json!({
            "agent": "copilot",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "copilot");
        assert_eq!(
            sessions[0]["messages"][0]["text"],
            "Ask Copilot about LicoLite"
        );
    }

    #[test]
    fn vscode_hosted_copilot_files_keep_copilot_as_source_client() {
        let dir = temp_dir("vscode-hosted-copilot");
        let transcript_dir = dir.join(
            "Library/Application Support/Code/User/workspaceStorage/ws/GitHub.copilot-chat/transcripts",
        );
        fs::create_dir_all(&transcript_dir).unwrap();
        fs::write(
            transcript_dir.join("copilot-session.jsonl"),
            r#"{"sessionId":"copilot-session","role":"user","content":"Ask Copilot about Pact"}"#,
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "code",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["adapterId"], "code");
        assert_eq!(sessions[0]["sourceTool"], "copilot");
        assert_eq!(sessions[0]["sourceClient"], "copilot");
        assert_eq!(sessions[0]["hostApp"], "vscode");
        assert_eq!(sessions[0]["sourceLabel"], "vscode: copilot");
    }

    #[test]
    fn every_supported_agent_has_dedicated_history_adapter() {
        for agent in [
            "antigravity",
            "claude-code",
            "code",
            "codex",
            "copilot",
            "cursor",
            "hermes",
            "kilo-code",
            "kimi",
            "openclaw",
            "opencode",
        ] {
            let dir = temp_dir(&format!("{}-adapter", agent));
            fs::write(
                dir.join("session.json"),
                format!(
                    r#"{{
                      "sessions": [{{
                        "sessionId": "{agent}-session",
                        "messages": [
                          {{"role": "user", "text": "{agent} native prompt"}},
                          {{"role": "assistant", "text": "{agent} native answer"}}
                        ]
                      }}]
                    }}"#
                ),
            )
            .unwrap();

            let listed = conversation_list(&json!({
                "agent": agent,
                "root": dir.to_string_lossy()
            }))
            .unwrap();

            assert_eq!(listed["adapterId"], agent);
            assert_eq!(listed["importMode"], "precise-adapter");
            assert_eq!(listed["sessions"][0]["adapterId"], agent);
            assert_eq!(
                listed["sessions"][0]["nativeSessionId"],
                format!("{}-session", agent)
            );
        }
    }

    #[test]
    fn openclaw_gateway_session_key_is_the_native_continuity_id() {
        let dir = temp_dir("openclaw-session-key");
        fs::write(
            dir.join("session.json"),
            r#"{
              "sessions": [{
                "sessionKey": "agent:main:fixture-thread",
                "messages": [
                  {"role": "user", "text": "OpenClaw native prompt"},
                  {"role": "assistant", "text": "OpenClaw native answer"}
                ]
              }]
            }"#,
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "openclaw",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(
            listed["sessions"][0]["nativeSessionId"],
            "agent:main:fixture-thread"
        );
    }

    #[test]
    fn unsupported_history_adapter_is_rejected() {
        let error = conversation_list(&json!({"agent": "unknown-agent"})).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("unsupported native history adapter")
        );
    }

    #[test]
    fn native_history_is_read_only() {
        assert!(conversation_append(&json!({})).is_err());
        assert!(conversation_delete(&json!({})).is_err());
    }

    #[test]
    fn sqlite_history_preserves_user_record_rows() {
        let dir = temp_dir("sqlite-history");
        let database = dir.join("state.vscdb");
        {
            let connection = Connection::open(&database).unwrap();
            connection
                .execute(
                    "CREATE TABLE ItemTable (key TEXT NOT NULL, value TEXT NOT NULL)",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                    ["chat.first", "user message: First native conversation turn"],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                    [
                        "chat.second",
                        "assistant message: Second native conversation turn",
                    ],
                )
                .unwrap();
        }

        let listed = conversation_list(&json!({
            "agent": "cursor",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        let total_messages = sessions
            .iter()
            .map(|session| session["messages"].as_array().unwrap().len())
            .sum::<usize>();
        assert_eq!(total_messages, 1);
        assert!(
            sessions
                .iter()
                .any(|session| session["nativeSessionId"] == "chat.first")
        );
    }

    #[test]
    fn native_history_skips_dependency_directories() {
        let dir = temp_dir("dependency-history");
        let dependency = dir.join("node_modules/pkg");
        fs::create_dir_all(&dependency).unwrap();
        fs::write(
            dependency.join("README.md"),
            "user: unrelated dependency mentions pact\nassistant: not history",
        )
        .unwrap();
        fs::write(
            dir.join("session.md"),
            "user: real pact conversation\nassistant: archived",
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        let sessions = listed["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0]["sourcePath"],
            display_path(&dir.join("session.md"))
        );
        assert!(
            listed["sources"]["skipped"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["reason"] == "excluded_non_history_directory")
        );
    }

    #[test]
    fn adapters_emit_semantic_layers_with_raw_evidence_refs() {
        let root = temp_dir("semantic-adapters");

        let codex_dir = root.join("codex");
        fs::create_dir_all(&codex_dir).unwrap();
        fs::write(
            codex_dir.join("session.jsonl"),
            [
                r#"{"sessionId":"codex-semantic","role":"user","content":"Codex semantic prompt"}"#,
                r#"{"sessionId":"codex-semantic","role":"assistant","content":"Codex semantic reply"}"#,
                r#"{"sessionId":"codex-semantic","type":"tool_use","name":"shell","input":{"command":"echo hi"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let claude_dir = root.join("claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("session.jsonl"),
            [
                r#"{"sessionId":"claude-semantic","type":"user","message":{"role":"user","content":[{"type":"text","text":"Claude semantic prompt"}]}}"#,
                r#"{"sessionId":"claude-semantic","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Claude semantic reply"},{"type":"tool_use","id":"1","name":"Read","input":{"path":"AGENTS.md"}}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let antigravity_dir = root.join("antigravity");
        fs::create_dir_all(&antigravity_dir).unwrap();
        fs::write(
            antigravity_dir.join("session.json"),
            serde_json::to_string_pretty(&json!({
                "sessions": [{
                    "sessionId": "antigravity-semantic",
                    "messages": [
                        {"role":"user","content":"<USER_REQUEST>Antigravity semantic prompt</USER_REQUEST>"},
                        {"role":"view_file","content":"file contents"},
                        {"role":"planner_response","content":"Antigravity semantic reply"}
                    ]
                }]
            }))
            .unwrap(),
        )
        .unwrap();

        let cursor_dir = root.join("cursor");
        fs::create_dir_all(&cursor_dir).unwrap();
        let cursor_db = cursor_dir.join("state.vscdb");
        {
            let connection = Connection::open(&cursor_db).unwrap();
            connection
                .execute(
                    "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)",
                    [],
                )
                .unwrap();
            let payload = serde_json::to_vec(&json!({
                "messages": [
                    {"role":"user","text":"Cursor semantic prompt"},
                    {"role":"assistant","text":"Cursor semantic reply"}
                ]
            }))
            .unwrap();
            connection
                .execute(
                    "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                    rusqlite::params!["composerData:chat", payload],
                )
                .unwrap();
        }

        for (agent, dir) in [
            ("codex", &codex_dir),
            ("claude-code", &claude_dir),
            ("antigravity", &antigravity_dir),
            ("cursor", &cursor_dir),
        ] {
            let listed = conversation_list(&json!({
                "agent": agent,
                "root": display_path(dir)
            }))
            .unwrap();
            let sessions = listed["sessions"].as_array().unwrap();
            assert!(
                !sessions.is_empty(),
                "{agent} should produce at least one semantic session"
            );
            let session = &sessions[0];
            assert_eq!(session["readOnly"], true);
            let semantic = session.get("semantic").expect("semantic document required");
            crate::domain::conversation_semantic::validate_semantic_conversation(semantic)
                .unwrap_or_else(|error| panic!("{agent} semantic invalid: {error}"));
            assert_eq!(semantic["kind"], "semantic-conversation");
            assert_eq!(semantic["privacyDefaults"]["defaultView"], "thread");
            assert!(
                semantic["thread"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|event| event["role"] == "user"),
                "{agent} thread should include a user message"
            );
            let evidence = &semantic["raw"]["evidenceRefs"][0];
            assert!(!evidence["pathRef"].as_str().unwrap_or_default().is_empty());
            assert!(
                !evidence["contentHash"]
                    .as_str()
                    .unwrap_or_default()
                    .is_empty()
            );
            assert!(
                !session["messages"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|message| message["layer"] == "raw"),
                "{agent} default messages must not include raw layer dumps"
            );
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("lico-client-{}-{}", name, now));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
