//! Bounded, platform-neutral discovery of local agent history files.

use super::source_catalog::{HistoryAdapter, HistoryRoot};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const MAX_HISTORY_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_HISTORY_FILES: usize = 8_000;
const MAX_HISTORY_DIRECTORY_ENTRIES: usize = 16_000;
const MAX_HISTORY_DIRECTORY_DEPTH: usize = 32;

#[derive(Clone, Debug)]
pub(crate) struct HistoryFileCandidate {
    pub(crate) path: PathBuf,
    pub(crate) source_kind: String,
    pub(crate) modified_at: SystemTime,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct HistoryDiscoveryOptions {
    pub(crate) archive_mode: bool,
    /// Identities the caller asked for. A file matches when any of them names
    /// it. More than one identity appears when a conversation's delegated work
    /// lives in its own file under its own identity, as Codex records it.
    pub(crate) exact_session_ids: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct HistoryDiscovery {
    pub(crate) candidates: Vec<HistoryFileCandidate>,
    pub(crate) skipped: Vec<Value>,
    pub(crate) files_seen: usize,
    pub(crate) directory_entries_seen: usize,
}

pub(crate) fn discover_history_files(
    adapter: HistoryAdapter,
    roots: &[HistoryRoot],
    options: HistoryDiscoveryOptions,
) -> HistoryDiscovery {
    let mut discovery = HistoryDiscovery::default();
    for root in roots {
        discover_path(
            adapter,
            &root.path,
            &root.source_kind,
            &options,
            &mut discovery,
            0,
        );
        if !options.archive_mode && discovery.files_seen >= MAX_HISTORY_FILES {
            break;
        }
    }
    discovery
}

fn discover_path(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    options: &HistoryDiscoveryOptions,
    discovery: &mut HistoryDiscovery,
    depth: usize,
) {
    if !options.archive_mode && discovery.files_seen >= MAX_HISTORY_FILES {
        record_skip(discovery, path, "file_limit_reached");
        return;
    }
    if let Some(reason) = excluded_history_path_reason(path) {
        record_skip(discovery, path, reason);
        return;
    }
    if !path.exists() {
        record_skip(discovery, path, "not_present");
        return;
    }
    if path.is_dir() {
        if depth >= MAX_HISTORY_DIRECTORY_DEPTH {
            record_skip(discovery, path, "directory_depth_limit_reached");
            return;
        }
        let entries = match fs::read_dir(path) {
            Ok(entries) => entries,
            Err(error) => {
                discovery.skipped.push(json!({
                    "path": display_path(path),
                    "reason": "read_dir_failed",
                    "error": error.to_string()
                }));
                return;
            }
        };
        for entry in entries.flatten() {
            if discovery.directory_entries_seen >= MAX_HISTORY_DIRECTORY_ENTRIES {
                record_skip(discovery, path, "directory_entry_limit_reached");
                break;
            }
            discovery.directory_entries_seen = discovery.directory_entries_seen.saturating_add(1);
            discover_path(
                adapter,
                &entry.path(),
                source_kind,
                options,
                discovery,
                depth.saturating_add(1),
            );
            if !options.archive_mode && discovery.files_seen >= MAX_HISTORY_FILES {
                break;
            }
        }
        return;
    }

    if !exact_session_candidate(adapter, path, source_kind, options) {
        return;
    }
    discovery.files_seen = discovery.files_seen.saturating_add(1);
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => {
            discovery.skipped.push(json!({
                "path": display_path(path),
                "reason": "metadata_failed",
                "error": error.to_string()
            }));
            return;
        }
    };
    if !options.archive_mode
        && metadata.len() > MAX_HISTORY_FILE_BYTES
        && !history_file_can_exceed_byte_limit(adapter, path)
    {
        discovery.skipped.push(json!({
            "path": display_path(path),
            "reason": "file_too_large",
            "bytes": metadata.len()
        }));
        return;
    }
    let extension = extension(path);
    if !adapter.accepts_file(path, &extension) {
        return;
    }
    discovery.candidates.push(HistoryFileCandidate {
        path: path.to_path_buf(),
        source_kind: source_kind.to_owned(),
        modified_at: metadata.modified().unwrap_or(UNIX_EPOCH),
    });
}

fn exact_session_candidate(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    options: &HistoryDiscoveryOptions,
) -> bool {
    if options.exact_session_ids.is_empty() {
        return true;
    }
    options
        .exact_session_ids
        .iter()
        .any(|session_id| exact_session_candidate_for_id(adapter, path, source_kind, session_id))
}

fn exact_session_candidate_for_id(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    session_id: &str,
) -> bool {
    match (adapter, source_kind) {
        (HistoryAdapter::Codex, "codex-session-store" | "codex-archived-session-store") => path
            .file_stem()
            .and_then(|name| name.to_str())
            .is_some_and(|stem| stem == session_id || stem.ends_with(&format!("-{session_id}"))),
        // Cursor and Claude Code keep one directory per conversation and put each
        // delegated task inside it under its own name, so matching only the file
        // name would drop every delegated task of the requested conversation.
        // Matching any path component also keeps the read from parsing every
        // conversation of every project.
        // Kimi Code keeps every agent of one conversation under
        // `<session>/agents/<id>/wire.jsonl`, so the conversation directory is the
        // only part of the path that names it.
        (HistoryAdapter::Cursor, "cursor-cli-chats" | "cursor-cli-projects")
        | (HistoryAdapter::ClaudeCode, "claude-project-transcripts")
        | (HistoryAdapter::KimiCode, "kimi-code-session-store") => {
            path_identity_matches(path, session_id)
        }
        (
            HistoryAdapter::Codex,
            "codex-prompt-history"
            | "codex-session-index"
            | "codex-memory"
            | "codex-rollout-summary",
        ) => false,
        _ => true,
    }
}

fn path_identity_matches(path: &Path, session_id: &str) -> bool {
    path.components()
        .filter_map(|component| component.as_os_str().to_str())
        .any(|component| component == session_id)
        || path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .is_some_and(|stem| stem == session_id)
}

fn history_file_can_exceed_byte_limit(adapter: HistoryAdapter, path: &Path) -> bool {
    let extension = extension(path);
    matches!(extension.as_str(), "sqlite" | "sqlite3" | "db" | "vscdb")
        && adapter.accepts_file(path, &extension)
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
    if let Some(reason) = excluded_delegated_bookkeeping_reason(path, &components) {
        return Some(reason);
    }
    components
        .iter()
        .any(|name| {
            matches!(
                *name,
                "node_modules" | ".git" | "target" | "build" | "dist" | ".next"
            )
        })
        .then_some("excluded_non_history_directory")
}

/// Bookkeeping an agent writes beside a delegated task.
///
/// Claude Code stores `<task>.meta.json`, `journal.jsonl`, and raw
/// `tool-results/` output next to the task transcripts. None of them is a
/// conversation, and `<task>.meta.json` is actively harmful: it carries no
/// session field, so the generic reader falls back to the nearest conversation
/// directory and the record claims the conversation's own identity. The delegated
/// tasks then attach to that record instead of the conversation and disappear
/// from it.
fn excluded_delegated_bookkeeping_reason(path: &Path, components: &[&str]) -> Option<&'static str> {
    if components.iter().any(|name| *name == "tool-results") {
        return Some("excluded_raw_tool_output");
    }
    if !components.iter().any(|name| *name == "subagents") {
        return None;
    }
    let stem = path.file_stem().and_then(|value| value.to_str())?;
    (stem == "journal" || stem.ends_with(".meta")).then_some("excluded_delegated_task_bookkeeping")
}

fn record_skip(discovery: &mut HistoryDiscovery, path: &Path, reason: &'static str) {
    discovery.skipped.push(json!({
        "path": display_path(path),
        "reason": reason
    }));
}

fn extension(path: &Path) -> String {
    path.extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("lico-conversation-discovery-{label}-{nonce}"))
    }

    #[test]
    fn discovery_accepts_history_and_prunes_non_history_trees() {
        let root = temp_root("bounded");
        fs::create_dir_all(root.join("sessions")).unwrap();
        fs::create_dir_all(root.join("node_modules/package")).unwrap();
        fs::write(root.join("sessions/session.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("node_modules/package/ignored.jsonl"), b"{}\n").unwrap();
        let roots = [HistoryRoot {
            path: root.clone(),
            source_kind: "test".to_owned(),
        }];
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &roots,
            HistoryDiscoveryOptions::default(),
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(
            discovery
                .skipped
                .iter()
                .any(|skip| skip["reason"] == "excluded_non_history_directory")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_codex_discovery_only_keeps_the_requested_rollout() {
        let root = temp_root("exact");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("rollout-wanted.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("rollout-other.jsonl"), b"{}\n").unwrap();
        let roots = [HistoryRoot {
            path: root.clone(),
            source_kind: "codex-session-store".to_owned(),
        }];
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &roots,
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(
            discovery.candidates[0]
                .path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.contains("wanted"))
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_codex_discovery_rejects_substring_identity_collisions() {
        let root = temp_root("exact-codex-collision");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("rollout-2026-wanted.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("rollout-2026-wanted-extra.jsonl"), b"{}\n").unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "codex-session-store".to_owned(),
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert_eq!(
            discovery.candidates[0]
                .path
                .file_name()
                .and_then(|name| name.to_str()),
            Some("rollout-2026-wanted.jsonl")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_cursor_chat_discovery_matches_a_whole_session_component() {
        let root = temp_root("exact-cursor-chat");
        fs::create_dir_all(root.join("project/wanted")).unwrap();
        fs::create_dir_all(root.join("project/wanted-extra")).unwrap();
        fs::write(root.join("project/wanted/store.db"), b"fixture").unwrap();
        fs::write(root.join("project/wanted-extra/store.db"), b"fixture").unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Cursor,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "cursor-cli-chats".to_owned(),
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(discovery.candidates[0].path.ends_with("wanted/store.db"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_claude_discovery_only_keeps_the_requested_transcript() {
        let root = temp_root("exact-claude");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("wanted.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("other.jsonl"), b"{}\n").unwrap();
        let roots = [HistoryRoot {
            path: root.clone(),
            source_kind: "claude-project-transcripts".to_owned(),
        }];
        let discovery = discover_history_files(
            HistoryAdapter::ClaudeCode,
            &roots,
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert_eq!(
            discovery.candidates[0]
                .path
                .file_name()
                .and_then(|name| name.to_str()),
            Some("wanted.jsonl")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_discovery_keeps_delegated_transcripts_of_the_requested_conversation() {
        let root = temp_root("exact-delegated");
        let conversation = root.join("wanted");
        fs::create_dir_all(conversation.join("subagents")).unwrap();
        fs::create_dir_all(root.join("other/subagents")).unwrap();
        fs::write(root.join("wanted.jsonl"), b"{}\n").unwrap();
        fs::write(
            conversation.join("subagents").join("agent-task.jsonl"),
            b"{}\n",
        )
        .unwrap();
        fs::write(root.join("other.jsonl"), b"{}\n").unwrap();
        fs::write(
            root.join("other/subagents").join("agent-elsewhere.jsonl"),
            b"{}\n",
        )
        .unwrap();
        for adapter in [HistoryAdapter::ClaudeCode, HistoryAdapter::Cursor] {
            let source_kind = match adapter {
                HistoryAdapter::Cursor => "cursor-cli-projects",
                _ => "claude-project-transcripts",
            };
            let roots = [HistoryRoot {
                path: root.clone(),
                source_kind: source_kind.to_owned(),
            }];
            let discovery = discover_history_files(
                adapter,
                &roots,
                HistoryDiscoveryOptions {
                    archive_mode: false,
                    exact_session_ids: vec!["wanted".to_owned()],
                },
            );
            let mut names = discovery
                .candidates
                .iter()
                .filter_map(|candidate| candidate.path.file_name())
                .filter_map(|name| name.to_str())
                .map(str::to_string)
                .collect::<Vec<_>>();
            names.sort();
            assert_eq!(
                names,
                vec!["agent-task.jsonl".to_string(), "wanted.jsonl".to_string()],
                "a delegated task of the requested conversation must stay in scope"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovery_stops_at_the_global_directory_entry_bound() {
        let root = temp_root("entry-bound");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("rollout-bound.jsonl"), b"{}\n").unwrap();
        let mut discovery = HistoryDiscovery {
            directory_entries_seen: MAX_HISTORY_DIRECTORY_ENTRIES,
            ..HistoryDiscovery::default()
        };
        discover_path(
            HistoryAdapter::Codex,
            &root,
            "codex-session-store",
            &HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["bound".to_owned()],
            },
            &mut discovery,
            0,
        );
        assert!(discovery.candidates.is_empty());
        assert_eq!(discovery.files_seen, 0);
        assert!(discovery.skipped.iter().any(|entry| {
            entry.get("reason").and_then(Value::as_str) == Some("directory_entry_limit_reached")
        }));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sqlite_history_files_can_exceed_the_text_byte_limit() {
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
}
