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
            root.explicitly_selected,
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
    explicitly_selected: bool,
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
    if !explicitly_selected
        && crate::domain::targets::scan_paths::denied(
            path,
            crate::platform::paths::user_home_from_env().as_deref(),
        )
    {
        record_skip(discovery, path, "denied_personal_location");
        return;
    }
    if crate::domain::targets::scan_paths::symlink_escapes_denied_location(path) {
        record_skip(discovery, path, "denied_symlink_escape");
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
        // Directed exact lookup visits only deterministic layout paths: once a
        // tree-identity store puts conversation directories at a known depth,
        // siblings that no requested identity can name are skipped without
        // descending. Structural directories (`agent-transcripts`, `agents`)
        // and every ancestor of a requested identity are always kept, so
        // delegated tasks inside a conversation directory stay discoverable.
        if exact_directory_can_be_pruned(
            adapter,
            source_kind,
            path,
            &options.exact_session_ids,
            depth,
        ) {
            record_skip(discovery, path, "exact_session_miss");
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
                explicitly_selected,
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

/// Whether a directory cannot hold any file of the requested exact sessions
/// and should be skipped without descending. Only tree-identity stores with a
/// deterministic conversation-directory depth are pruned; every other adapter
/// keeps its bounded full walk and the per-file identity predicate.
fn exact_directory_can_be_pruned(
    adapter: HistoryAdapter,
    source_kind: &str,
    path: &Path,
    exact_session_ids: &[String],
    depth: usize,
) -> bool {
    if exact_session_ids.is_empty() {
        return false;
    }
    let (prunable_from, structural) = match (adapter, source_kind) {
        (HistoryAdapter::Cursor, "cursor-cli-chats") => (2usize, &[][..]),
        (HistoryAdapter::Cursor, "cursor-cli-projects") => (2, &["agent-transcripts"][..]),
        (HistoryAdapter::ClaudeCode, "claude-project-transcripts") => (2, &[][..]),
        (HistoryAdapter::KimiCode, "kimi-code-session-store") => (2, &["agents"][..]),
        _ => return false,
    };
    if depth < prunable_from {
        return false;
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if structural.contains(&name) {
        return false;
    }
    let any_id_in_path = path
        .components()
        .filter_map(|component| component.as_os_str().to_str())
        .any(|component| exact_session_ids.iter().any(|id| component == id));
    !any_id_in_path
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
    if components.contains(&"tool-results") {
        return Some("excluded_raw_tool_output");
    }
    if !components.contains(&"subagents") {
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
            explicitly_selected: false,
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
    fn discovery_does_not_stat_denied_network_volumes() {
        fn posix(parts: &[&str]) -> PathBuf {
            PathBuf::from(format!("/{}", parts.join("/")))
        }
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &[HistoryRoot {
                path: posix(&["Volumes", "team-share", "sessions"]),
                source_kind: "codex-session-store".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions::default(),
        );
        assert!(discovery.candidates.is_empty());
        assert!(
            discovery
                .skipped
                .iter()
                .any(|skip| skip["reason"] == "denied_personal_location")
        );
    }

    #[test]
    fn explicitly_selected_root_is_not_rejected_as_automatic_discovery() {
        let path = PathBuf::from(format!(
            "/{}",
            ["Volumes", "selected", "sessions"].join("/")
        ));
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &[HistoryRoot {
                path,
                source_kind: "codex-session-store".to_owned(),
                explicitly_selected: true,
            }],
            HistoryDiscoveryOptions::default(),
        );
        assert!(
            !discovery
                .skipped
                .iter()
                .any(|skip| skip["reason"] == "denied_personal_location")
        );
    }

    #[cfg(unix)]
    #[test]
    fn discovery_does_not_follow_symlink_into_personal_library() {
        let Some(home) = crate::platform::paths::user_home_from_env() else {
            return;
        };
        let root = temp_root("symlink-escape");
        fs::create_dir_all(&root).unwrap();
        let link = root.join("escaped-session.jsonl");
        std::os::unix::fs::symlink(home.join("Desktop").join("secret-session.jsonl"), &link)
            .unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "codex-session-store".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions::default(),
        );
        assert!(discovery.candidates.is_empty());
        assert!(
            discovery
                .skipped
                .iter()
                .any(|skip| skip["reason"] == "denied_symlink_escape")
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
            explicitly_selected: false,
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
                explicitly_selected: false,
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
                explicitly_selected: false,
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
            explicitly_selected: false,
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
                explicitly_selected: false,
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
            false,
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
    fn exact_cursor_projects_prune_unrelated_project_trees() {
        let root = temp_root("exact-prune-projects");
        let wanted = root.join("wanted-project/agent-transcripts/session-abc");
        fs::create_dir_all(&wanted).unwrap();
        fs::write(wanted.join("session-abc.jsonl"), b"{}\n").unwrap();
        let unrelated = root.join("other-project/agent-transcripts/session-xyz");
        fs::create_dir_all(&unrelated).unwrap();
        fs::write(unrelated.join("session-xyz.jsonl"), b"{}\n").unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Cursor,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "cursor-cli-projects".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["session-abc".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(discovery.candidates[0].path.ends_with("session-abc.jsonl"));
        assert!(
            discovery
                .skipped
                .iter()
                .any(|entry| entry.get("reason").and_then(Value::as_str)
                    == Some("exact_session_miss")),
            "the unrelated conversation directory is pruned, not descended"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_claude_prunes_unrelated_project_children_only() {
        let root = temp_root("exact-prune-claude");
        let wanted_project = root.join("wanted-project");
        fs::create_dir_all(wanted_project.join("wanted/subagents")).unwrap();
        fs::write(wanted_project.join("wanted.jsonl"), b"{}\n").unwrap();
        fs::write(
            wanted_project.join("wanted/subagents/agent-task.jsonl"),
            b"{}\n",
        )
        .unwrap();
        fs::create_dir_all(wanted_project.join("unrelated-dir")).unwrap();
        fs::write(wanted_project.join("unrelated-dir/nested.jsonl"), b"{}\n").unwrap();
        let other_project = root.join("other-project");
        fs::create_dir_all(&other_project).unwrap();
        fs::write(other_project.join("other.jsonl"), b"{}\n").unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::ClaudeCode,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "claude-project-transcripts".to_owned(),
                explicitly_selected: false,
            }],
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
            .collect::<Vec<_>>();
        names.sort();
        assert_eq!(names, vec!["agent-task.jsonl", "wanted.jsonl"]);
        assert!(
            discovery
                .skipped
                .iter()
                .any(|entry| entry.get("reason").and_then(Value::as_str)
                    == Some("exact_session_miss")),
            "the unrelated conversation directory is pruned"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_chats_prune_sibling_chat_dirs_but_keep_hash_ancestors() {
        let root = temp_root("exact-prune-chats");
        fs::create_dir_all(root.join("ab12cd34/wanted")).unwrap();
        fs::create_dir_all(root.join("ab12cd34/other")).unwrap();
        fs::write(root.join("ab12cd34/wanted/meta.json"), b"{}\n").unwrap();
        fs::write(root.join("ab12cd34/other/meta.json"), b"{}\n").unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Cursor,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "cursor-cli-chats".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(discovery.candidates[0].path.ends_with("wanted/meta.json"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_kimi_keeps_agents_of_the_requested_session_only() {
        let root = temp_root("exact-prune-kimi");
        fs::create_dir_all(root.join("workdir-a/session-one/agents/agent-1")).unwrap();
        fs::create_dir_all(root.join("workdir-a/session-two/agents/agent-1")).unwrap();
        fs::write(
            root.join("workdir-a/session-one/agents/agent-1/wire.jsonl"),
            b"{}\n",
        )
        .unwrap();
        fs::write(
            root.join("workdir-a/session-two/agents/agent-1/wire.jsonl"),
            b"{}\n",
        )
        .unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::KimiCode,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "kimi-code-session-store".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["session-one".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(
            discovery.candidates[0]
                .path
                .ends_with("session-one/agents/agent-1/wire.jsonl")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn exact_codex_rollouts_stay_unpruned_because_sessions_are_flat_files() {
        let root = temp_root("exact-unpruned-codex");
        fs::create_dir_all(root.join("2026/08/01")).unwrap();
        fs::write(
            root.join("2026/08/01/rollout-2026-08-01T00-00-00-wanted.jsonl"),
            b"{}\n",
        )
        .unwrap();
        fs::write(
            root.join("2026/08/01/rollout-2026-08-01T00-00-01-other.jsonl"),
            b"{}\n",
        )
        .unwrap();
        let discovery = discover_history_files(
            HistoryAdapter::Codex,
            &[HistoryRoot {
                path: root.clone(),
                source_kind: "codex-session-store".to_owned(),
                explicitly_selected: false,
            }],
            HistoryDiscoveryOptions {
                archive_mode: false,
                exact_session_ids: vec!["wanted".to_owned()],
            },
        );
        assert_eq!(discovery.candidates.len(), 1);
        assert!(
            discovery.candidates[0]
                .path
                .ends_with("rollout-2026-08-01T00-00-00-wanted.jsonl")
        );
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
