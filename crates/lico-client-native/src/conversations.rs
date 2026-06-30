use anyhow::{Result, anyhow};
use rusqlite::Connection;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const CONVERSATION_SCHEMA_VERSION: u32 = 2;
const MAX_HISTORY_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_HISTORY_FILES: usize = 8_000;
const MAX_SQLITE_ROWS_PER_TABLE: usize = 2_000;
const ARCHIVE_SQLITE_PAGE_ROWS: usize = 2_000;
const ARCHIVE_DISCOVERY_PREVIEW_MESSAGES: usize = 12;
const ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS: usize = 8_000;

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
    OpenClaw,
    OpenCode,
}

struct HistoryRoot {
    path: PathBuf,
    source_kind: String,
}

#[derive(Clone, Debug)]
struct HistoryScanConfig {
    archive_mode: bool,
    match_terms: Vec<String>,
    match_project_paths: Vec<String>,
}

impl HistoryScanConfig {
    fn from_params(params: &Value) -> Self {
        Self {
            archive_mode: param_bool(params, "archiveMode").unwrap_or(false),
            match_terms: string_list_param(params, &["matchTerms", "matchTerm"]),
            match_project_paths: string_list_param(
                params,
                &["matchProjectPaths", "matchProjectPath"],
            ),
        }
    }

    fn matches_session(&self, session: &Value) -> bool {
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
            HistoryAdapter::OpenClaw => "openclaw",
            HistoryAdapter::OpenCode => "opencode",
        }
    }

    fn label(self) -> &'static str {
        match self {
            HistoryAdapter::Antigravity => "Antigravity",
            HistoryAdapter::ClaudeCode => "Claude Code",
            HistoryAdapter::Code => "VS Code",
            HistoryAdapter::Codex => "Codex",
            HistoryAdapter::Copilot => "GitHub Copilot",
            HistoryAdapter::Cursor => "Cursor",
            HistoryAdapter::Hermes => "Hermes Agent",
            HistoryAdapter::KiloCode => "Kilo Code",
            HistoryAdapter::OpenClaw => "OpenClaw",
            HistoryAdapter::OpenCode => "OpenCode",
        }
    }

    fn accepts_file(self, path: &Path, extension: &str) -> bool {
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
            HistoryAdapter::OpenCode | HistoryAdapter::OpenClaw | HistoryAdapter::Hermes => {
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
        "openclaw" => Some(HistoryAdapter::OpenClaw),
        "opencode" => Some(HistoryAdapter::OpenCode),
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

    for root in roots {
        scan_history_path(
            adapter,
            &root.path,
            &root.source_kind,
            scan_config.clone(),
            &mut sessions,
            &mut skipped,
            &mut files_seen,
        );
    }
    sessions.sort_by(|left, right| {
        right
            .get("updatedAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                left.get("updatedAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });

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
        "sources": {
            "filesSeen": files_seen,
            "skipped": skipped
        }
    }))
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
            scan_history_path(
                adapter,
                &entry.path(),
                source_kind,
                scan_config.clone(),
                sessions,
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
    if !scan_config.archive_mode && metadata.len() > MAX_HISTORY_FILE_BYTES {
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
    let parsed = match extension.as_str() {
        "jsonl" | "ndjson" => {
            parse_jsonl_sessions(adapter, path, source_kind, &metadata, scan_config.clone())
        }
        "json" => parse_json_sessions(adapter, path, source_kind, &metadata),
        "md" | "markdown" | "txt" | "log" => {
            parse_text_session(adapter, path, source_kind, &metadata)
        }
        "sqlite" | "sqlite3" | "db" | "vscdb" => {
            parse_sqlite_sessions(adapter, path, source_kind, &metadata, scan_config.clone())
        }
        _ => Vec::new(),
    };
    sessions.extend(
        parsed
            .into_iter()
            .filter(|session| scan_config.matches_session(session))
            .map(|session| scan_config.compact_session_for_archive_discovery(session)),
    );
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
    if adapter == HistoryAdapter::Codex {
        if let Some(sessions) =
            parse_codex_rollout_sessions(path, source_kind, metadata, scan_config.clone())
        {
            return sessions;
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

#[derive(Debug)]
struct CodexRolloutGroup {
    session_id: String,
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

    if let Some(message) = codex_rollout_message(path, index, event_type, payload, &value) {
        push_codex_rollout_message(groups, session_id, message, cwd, scan_config);
    } else if cwd.is_some() {
        if scan_config.has_match_filters() {
            update_codex_rollout_group_cwd(groups, session_id, cwd);
            return;
        }
        let message = codex_rollout_metadata_message(path, index, event_type, payload, &value);
        push_codex_rollout_message(groups, session_id, message, cwd, scan_config);
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
        messages: Vec::new(),
        cwd,
        matched_terms: BTreeSet::new(),
        message_count: 0,
        preview_count: 0,
    });
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
        "session_meta" | "turn_context" => Some(codex_rollout_metadata_message(
            path, index, event_type, payload, raw_value,
        )),
        "response_item" => codex_response_item_message(path, index, payload, raw_value),
        _ => None,
    }
}

fn codex_rollout_metadata_message(
    path: &Path,
    index: usize,
    event_type: &str,
    payload: &Value,
    raw_value: &Value,
) -> Value {
    let mut parts = Vec::<String>::new();
    for key in [
        "cwd",
        "workingDirectory",
        "projectPath",
        "originator",
        "source",
        "thread_source",
        "cli_version",
    ] {
        if let Some(text) = payload.get(key).and_then(Value::as_str) {
            if !text.trim().is_empty() {
                parts.push(format!("{}: {}", key, text));
            }
        }
    }
    if parts.is_empty() {
        parts.push(format!("codex event: {}", event_type));
    }
    json!({
        "id": message_id(HistoryAdapter::Codex.id(), path, index),
        "role": "metadata",
        "text": parts.join("\n"),
        "createdAt": extract_timestamp(raw_value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        }),
        "sourcePath": display_path(path),
        "sourceEventType": event_type
    })
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
    if matches!(item_type, "function_call" | "function_call_output") {
        return None;
    }
    let text = match item_type {
        _ => payload
            .get("content")
            .or_else(|| payload.get("text"))
            .or_else(|| payload.get("summary"))
            .and_then(extract_text),
    }?;
    if text.trim().is_empty() || metadata_like_text(&text) {
        return None;
    }
    let role = extract_role(payload);
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
        if let Some(message) = message_from_json(adapter, path, index, &value) {
            let session_id =
                extract_native_session_id(&value).unwrap_or_else(|| "file".to_string());
            push_grouped_message(grouped, session_id, message);
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
    let connection = match Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_URI
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(connection) => connection,
        Err(_) => return Vec::new(),
    };
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
                if let Some(message) = message_from_json(adapter, path, index, item) {
                    out.push(message);
                } else {
                    collect_messages_from_value(adapter, path, item, out);
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
                if let Some(message) = message_from_json(adapter, path, 0, value) {
                    out.push(message);
                }
            }
        }
        _ => {}
    }
}

fn message_from_json(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    value: &Value,
) -> Option<Value> {
    let text = extract_text(value)?;
    if text.trim().is_empty() {
        return None;
    }
    let mut message = json!({
        "id": message_id(adapter.id(), path, index),
        "role": extract_role(value),
        "text": text,
        "createdAt": extract_timestamp(value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        }),
        "sourcePath": display_path(path)
    });
    if let Some(usage) = extract_token_usage(value) {
        if let Some(object) = message.as_object_mut() {
            object.insert("usage".to_string(), usage);
        }
    }
    Some(message)
}

fn extract_token_usage(value: &Value) -> Option<Value> {
    let mut usage = UsageFields::default();
    collect_token_usage(value, 0, &mut usage);
    usage.to_json()
}

#[derive(Default)]
struct UsageFields {
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    explicit_fields: usize,
}

impl UsageFields {
    fn to_json(&self) -> Option<Value> {
        if self.explicit_fields == 0 {
            return None;
        }
        let total_tokens = if self.total_tokens > 0 {
            self.total_tokens
        } else {
            self.prompt_tokens + self.completion_tokens
        };
        Some(json!({
            "promptTokens": self.prompt_tokens,
            "completionTokens": self.completion_tokens,
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
    usage.prompt_tokens += token_count_field(
        object,
        &[
            "promptTokens",
            "prompt_tokens",
            "inputTokens",
            "input_tokens",
            "cacheReadInputTokens",
            "cache_read_input_tokens",
            "cacheCreationInputTokens",
            "cache_creation_input_tokens",
        ],
        usage,
    );
    usage.completion_tokens += token_count_field(
        object,
        &[
            "completionTokens",
            "completion_tokens",
            "outputTokens",
            "output_tokens",
            "responseTokens",
            "response_tokens",
        ],
        usage,
    );
    usage.total_tokens += token_count_field(object, &["totalTokens", "total_tokens"], usage);
    for key in [
        "usage",
        "tokenUsage",
        "token_usage",
        "responseUsage",
        "modelUsage",
        "message",
    ] {
        if let Some(child) = object.get(key) {
            collect_token_usage(child, depth + 1, usage);
        }
    }
}

fn token_count_field(
    object: &serde_json::Map<String, Value>,
    keys: &[&str],
    usage: &mut UsageFields,
) -> u64 {
    let mut total = 0u64;
    for key in keys {
        if let Some(value) = object.get(*key).and_then(token_count_value) {
            usage.explicit_fields += 1;
            total += value;
        }
    }
    total
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
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(items) => {
            let parts = items
                .iter()
                .filter_map(extract_text)
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join("\n"))
            }
        }
        Value::Object(object) => {
            for key in [
                "text", "content", "message", "prompt", "response", "answer", "summary", "value",
            ] {
                if let Some(text) = object.get(key).and_then(extract_text) {
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

fn extract_role(value: &Value) -> String {
    let role = find_string(value, &["role", "author", "speaker", "type", "source"])
        .unwrap_or_else(|| "system".to_string())
        .to_ascii_lowercase();
    if role.contains("user") || role.contains("human") {
        "user".to_string()
    } else if role.contains("assistant")
        || role.contains("agent")
        || role.contains("model")
        || role.contains("ai")
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
        ],
    )
    .filter(|value| !value.trim().is_empty())
}

fn sqlite_row_key(fields: &[(String, String)]) -> Option<String> {
    for preferred in ["key", "id", "sessionId", "session_id", "conversationId"] {
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
    let source_label = source_label(&host_app, &source_client);
    let title = explicit_title
        .filter(|title| !title.trim().is_empty())
        .map(|title| title_from_text(&title))
        .or_else(|| title_from_messages(&messages))
        .unwrap_or_else(|| fallback_conversation_title(adapter, path));
    json!({
        "id": session_id(adapter.id(), path, &native_session_id),
        "agentId": adapter.id(),
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sourceTool": source_client,
        "sourceClient": source_client,
        "sourceClientLabel": source_client_label(&source_client),
        "hostApp": host_app,
        "hostAppLabel": host_app_label(&host_app),
        "sourceLabel": source_label,
        "sourceKind": source_kind,
        "sourcePath": display_path(path),
        "nativeSessionId": native_session_id,
        "importMode": "precise-adapter",
        "title": title,
        "createdAt": created_at,
        "updatedAt": updated_at,
        "native": true,
        "readOnly": true,
        "messageCount": messages.len(),
        "messages": messages
    })
}

fn title_from_messages(messages: &[Value]) -> Option<String> {
    for preferred_role in ["user", "human"] {
        if let Some(title) = messages.iter().find_map(|message| {
            let role = message.get("role").and_then(Value::as_str).unwrap_or("");
            if role == preferred_role {
                message
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !metadata_like_text(text))
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
        if matches!(role, "metadata" | "system" | "record") {
            return None;
        }
        message
            .get("text")
            .and_then(Value::as_str)
            .filter(|text| !metadata_like_text(text))
            .map(title_from_message_text)
    })
}

fn title_from_message_text(text: &str) -> String {
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let lower = line.to_ascii_lowercase();
        for prefix in ["user:", "human:", "prompt:", "question:"] {
            if lower.starts_with(prefix) {
                return title_from_text(line[prefix.len()..].trim());
            }
        }
    }
    title_from_text(text)
}

fn extract_conversation_title(value: &Value) -> Option<String> {
    find_string(
        value,
        &[
            "title",
            "name",
            "conversationTitle",
            "chatTitle",
            "sessionTitle",
            "summary",
        ],
    )
    .filter(|title| !title.trim().is_empty() && !looks_like_generated_identity(title))
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
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("cwd:")
        || lower.starts_with("workingdirectory:")
        || lower.starts_with("projectpath:")
        || lower.starts_with("codex event:")
        || lower.starts_with("<environment_context>")
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
        "openclaw" => "OpenClaw",
        "opencode" => "OpenCode",
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
        "openclaw" => "OpenClaw",
        "opencode" => "OpenCode",
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
    }
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

fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

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
                r#"{"timestamp":"2026-06-03T10:53:55.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"rg Pact\"}"}}"#,
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
        assert!(messages.iter().any(|message| {
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
        assert!(!messages.iter().any(|message| message["role"] == "tool"));
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
    fn sqlite_history_preserves_multiple_record_rows() {
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
        assert_eq!(sessions.len(), 2);
        let total_messages = sessions
            .iter()
            .map(|session| session["messages"].as_array().unwrap().len())
            .sum::<usize>();
        assert_eq!(total_messages, 2);
        assert!(
            sessions
                .iter()
                .any(|session| session["nativeSessionId"] == "chat.second")
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
