use crate::core::safe_archive;
use crate::domain::conversations;
use crate::domain::targets;
use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, harden_private_tree,
};
use crate::platform::paths::portable_data_dir;
use crate::platform::runtime_adapters;
use anyhow::{Result, anyhow, ensure};
use rusqlite::Connection;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const COLLECTION_SCHEMA_VERSION: &str = "v0.0.1:agent:native-conversation-snapshot-1";
const MARKER_FILE: &str = ".lico-native-conversation-snapshots.json";
const COLLECTION_JSON: &str = "collection.json";
const SNAPSHOT_JSON: &str = "snapshot.json";
const DEFAULT_SNAPSHOT_ROOT_DIR: &str = "native-conversation-snapshots";
const SETTINGS_COLLECTION: &str = "settings";
const TARGETS_COLLECTION: &str = "targets";
const BRIDGES_COLLECTION: &str = "snapshot-bridges";
const PROFILES_COLLECTION: &str = "conversation-archive-profiles";
const BRIDGE_CONFIG_KEY: &str = "licoLiteSnapshotCurationBridge";
const CONVERSATION_INDEX_JSONL: &str = "conversation-index.jsonl";
const CONVERSATION_INDEX_MD: &str = "conversation-index.md";
const SUMMARY_MD: &str = "summary.md";
const SOURCES_JSON: &str = "sources.json";
const MATCHES_JSONL: &str = "matches.jsonl";
const VALIDATION_JSON: &str = "validation.json";
const SEMANTIC_JSON: &str = "semantic.json";
const SEMANTIC_MD: &str = "semantic.md";

const SUPPORTED_AGENTS: &[&str] = &[
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
];

#[derive(Clone, Debug)]
struct SnapshotRoot {
    path: PathBuf,
    mode: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ArchiveCollectionLayout {
    CollectionsSubdir,
    DirectKeywordFolders,
}

#[derive(Clone, Debug)]
struct SelectedCandidate {
    session: Value,
    selection_mode: String,
    reason: String,
    labels: Vec<String>,
    group: String,
    summary: String,
}

#[derive(Clone, Debug)]
struct RawExport {
    file_name: String,
    content: String,
    export_kind: String,
    diagnostics: Vec<Value>,
}

#[derive(Clone, Debug)]
struct KeywordArchiveRun {
    position: usize,
    keyword: String,
    run: Value,
}

#[derive(Clone, Debug)]
struct DiscoveryResult {
    agents: Vec<String>,
    candidates: Vec<Value>,
    source_summaries: Vec<Value>,
    diagnostics: Vec<Value>,
}

struct CuratorInvocation {
    curation: Value,
    structured_result: Option<Value>,
}

#[derive(Clone, Debug)]
struct ArchiveProfile {
    profile_id: String,
    display_name: String,
    collection_path_segments: Vec<String>,
    archive_root: Option<PathBuf>,
    canonical_names: Vec<String>,
    alias_names: Vec<String>,
    project_paths: Vec<String>,
    expected_agents: Vec<String>,
    expected_sources: Vec<String>,
    exclusion_rules: Vec<String>,
    baseline_index_path: Option<PathBuf>,
    raw: Value,
}

#[derive(Clone, Debug)]
struct ProfileMatch {
    matched_terms: Vec<String>,
    confidence: String,
    reason: String,
}

#[derive(Clone, Debug)]
struct ArchiveMaterializeWorkItem {
    position: usize,
    selected: SelectedCandidate,
    profile_match: ProfileMatch,
}

#[derive(Debug)]
struct ArchiveMaterializeResult {
    position: usize,
    archive_key: String,
    session: Value,
    profile_match: ProfileMatch,
    record: Value,
}

#[derive(Clone, Debug)]
struct RemoteHistoryTarget {
    candidate_id: String,
    agent_id: String,
    label: String,
    location: String,
    context_id: String,
    context_name: String,
    user: String,
    runtime_bin: String,
    relative_paths: Vec<String>,
}

pub fn root_get(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let root = snapshot_root(&store, params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "snapshotRoot": display_path(&root.path),
        "mode": root.mode,
        "configured": root.mode == "user-controlled",
        "markerPath": display_path(&root.path.join(MARKER_FILE))
    }))
}

pub fn root_set(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let Some(new_root_raw) = text_param(params, &["path", "root", "snapshotRoot"]) else {
        return Err(anyhow!("snapshots root set requires --path"));
    };
    let new_root = expand_home(&new_root_raw);
    let old_root = snapshot_root(&store, &json!({}))?;
    if equivalent_paths(&old_root.path, &new_root) {
        write_snapshot_root_setting(&store, &new_root)?;
        ensure_snapshot_root(&new_root)?;
        return Ok(json!({
            "ok": true,
            "status": "unchanged",
            "snapshotRoot": display_path(&new_root),
            "previousSnapshotRoot": display_path(&old_root.path),
            "migration": {"status": "not_needed"}
        }));
    }

    if new_root.exists() && !directory_is_empty(&new_root)? {
        return Ok(json!({
            "ok": false,
            "status": "directory_conflict",
            "snapshotRoot": display_path(&new_root),
            "previousSnapshotRoot": display_path(&old_root.path),
            "message": "Snapshot root already contains files. Choose an empty folder or keep the current root."
        }));
    }

    let migration = if old_root.path.exists() && old_root.path.join(MARKER_FILE).exists() {
        migrate_snapshot_root(&old_root.path, &new_root)?
    } else {
        ensure_snapshot_root(&new_root)?;
        json!({
            "status": "initialized",
            "from": display_path(&old_root.path),
            "to": display_path(&new_root)
        })
    };

    write_snapshot_root_setting(&store, &new_root)?;
    let activity = store.activity_log().append(
        "conversation_snapshots.root_set",
        json!({
            "target": "conversation-snapshots",
            "snapshotRoot": display_path(&new_root),
            "previousSnapshotRoot": display_path(&old_root.path),
            "migration": migration.clone()
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "set",
        "snapshotRoot": display_path(&new_root),
        "previousSnapshotRoot": display_path(&old_root.path),
        "migration": migration,
        "activity": activity
    }))
}

pub fn collections_list(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let root = snapshot_root(&store, params)?;
    let collections_dir = root.path.join("collections");
    let mut collections = Vec::<Value>::new();
    if collections_dir.exists() {
        collect_collection_summaries(&collections_dir, &mut collections)?;
    }
    collections.sort_by(|left, right| {
        right
            .get("refreshedAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                left.get("refreshedAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "snapshotRoot": display_path(&root.path),
        "collections": collections
    }))
}

fn collect_collection_summaries(dir: &Path, collections: &mut Vec<Value>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let path = entry.path();
        let collection_path = path.join(COLLECTION_JSON);
        if collection_path.exists() {
            let collection = read_json_or_default(&collection_path, || json!({}))?;
            collections.push(collection_summary(&collection, &collection_path));
            continue;
        }
        collect_collection_summaries(&path, collections)?;
    }
    Ok(())
}

pub fn curator_get(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let settings = store.read_collection(SETTINGS_COLLECTION)?;
    let preferred = settings
        .get("preferredSnapshotCurator")
        .cloned()
        .unwrap_or_else(|| json!(null));
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "configured": !preferred.is_null(),
        "preferredSnapshotCurator": preferred
    }))
}

pub fn curator_set(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let clear = param_bool(params, "clear").unwrap_or(false);
    let mut settings = store
        .read_collection(SETTINGS_COLLECTION)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    if clear {
        settings.remove("preferredSnapshotCurator");
        store.write_collection(SETTINGS_COLLECTION, Value::Object(settings))?;
        return Ok(json!({
            "ok": true,
            "status": "cleared",
            "preferredSnapshotCurator": null
        }));
    }
    let target = text_param(params, &["target", "agent", "agentId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshots curator set requires --target or --clear true"))?;
    let mut preferred = Map::<String, Value>::new();
    preferred.insert("target".to_string(), json!(normalize_agent_alias(&target)));
    for key in [
        "cwd",
        "workingDirectory",
        "timeoutMs",
        "maxStdoutBytes",
        "maxStderrBytes",
        "readBudget",
    ] {
        if let Some(value) = params.get(key) {
            if !value.is_null()
                && value
                    .as_str()
                    .map(|text| !text.trim().is_empty())
                    .unwrap_or(true)
            {
                preferred.insert(key.to_string(), value.clone());
            }
        }
    }
    let preferred = Value::Object(preferred);
    settings.insert("preferredSnapshotCurator".to_string(), preferred.clone());
    store.write_collection(SETTINGS_COLLECTION, Value::Object(settings))?;
    Ok(json!({
        "ok": true,
        "status": "set",
        "preferredSnapshotCurator": preferred
    }))
}

pub fn profiles_list(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let document = store.read_collection(PROFILES_COLLECTION)?;
    let mut profiles = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    profiles.sort_by(|left, right| {
        text_value(left, "profileId")
            .unwrap_or_default()
            .cmp(&text_value(right, "profileId").unwrap_or_default())
    });
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "profiles": profiles
    }))
}

pub fn profile_get(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let profile = load_archive_profile(&store, params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "profile": archive_profile_value(&profile)
    }))
}

pub fn profile_import(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let profile_value = archive_profile_input(params)?;
    let profile = parse_archive_profile(&profile_value)?;
    let normalized = archive_profile_value(&profile);
    let mut document = store
        .read_collection(PROFILES_COLLECTION)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    let mut items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(existing) = items.iter_mut().find(|item| {
        item.get("profileId").and_then(Value::as_str) == Some(profile.profile_id.as_str())
    }) {
        *existing = normalized.clone();
    } else {
        items.push(normalized.clone());
    }
    document.insert("items".to_string(), Value::Array(items));
    store.write_collection(PROFILES_COLLECTION, Value::Object(document))?;
    Ok(json!({
        "ok": true,
        "status": "imported",
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "profile": normalized
    }))
}

pub fn archive_run(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let profile = load_archive_profile(&store, params)?;
    let root = archive_root_for_profile(&store, params, &profile)?;
    run_archive_with_profile(&store, params, profile, root, "archive")
}

fn run_archive_with_profile(
    store: &ClientStateStore,
    params: &Value,
    profile: ArchiveProfile,
    root: PathBuf,
    entry: &str,
) -> Result<Value> {
    run_archive_with_profile_layout(
        store,
        params,
        profile,
        root,
        entry,
        ArchiveCollectionLayout::CollectionsSubdir,
    )
}

fn run_archive_with_profile_layout(
    store: &ClientStateStore,
    params: &Value,
    profile: ArchiveProfile,
    root: PathBuf,
    entry: &str,
    layout: ArchiveCollectionLayout,
) -> Result<Value> {
    let discovery = discover_archive_candidates(store, params, &profile);
    run_archive_with_profile_discovery(store, params, profile, root, entry, layout, &discovery)
}

fn run_archive_with_profile_discovery(
    store: &ClientStateStore,
    params: &Value,
    profile: ArchiveProfile,
    root: PathBuf,
    entry: &str,
    layout: ArchiveCollectionLayout,
    discovery: &DiscoveryResult,
) -> Result<Value> {
    ensure_snapshot_root(&root)?;
    let collection_dir = collection_dir_for_profile_layout(&root, &profile, layout);
    fs::create_dir_all(collection_dir.join("conversations"))?;
    let collection_path = collection_dir.join(COLLECTION_JSON);
    let existing = read_json_or_default(&collection_path, || {
        empty_collection(&profile.display_name, &profile.profile_id, &root)
    })?;
    let (selected, matches_by_id, curation) =
        select_profile_archive_candidates(store, params, &profile, discovery)?;
    let refreshed_at = timestamp_rfc3339();
    let mut conversations = existing_conversations(&existing);
    let previous_index = read_index_records(&collection_dir.join(CONVERSATION_INDEX_JSONL))?;
    let previous_by_key = index_records_by_archive_key(&previous_index);
    let mut current_keys = BTreeSet::<String>::new();
    let mut index_records = Vec::<Value>::new();
    let mut match_records = Vec::<Value>::new();
    let mut written = Vec::<Value>::new();

    let work_items = selected
        .into_iter()
        .enumerate()
        .map(|(position, selected_candidate)| {
            let candidate_id = candidate_id(&selected_candidate.session).unwrap_or_default();
            let profile_match = matches_by_id
                .get(&candidate_id)
                .cloned()
                .unwrap_or(ProfileMatch {
                    matched_terms: vec!["curated".to_string()],
                    confidence: "medium".to_string(),
                    reason: "structured curation selected this candidate".to_string(),
                });
            ArchiveMaterializeWorkItem {
                position,
                selected: selected_candidate,
                profile_match,
            }
        })
        .collect::<Vec<_>>();
    let mut materialized = materialize_archive_work_items_parallel(
        &collection_dir,
        &profile.display_name,
        &profile.profile_id,
        &refreshed_at,
        work_items,
        archive_parallelism(params),
    )?;

    materialized.sort_by_key(|item| item.position);
    for item in materialized {
        let profile_match = item.profile_match;
        let record = item.record;
        let archive_key = item.archive_key;
        current_keys.insert(archive_key.clone());
        let status = archive_status_for(
            previous_by_key.get(&archive_key),
            record
                .get("rawContentHash")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        );
        let index_record = archive_index_record(
            &archive_key,
            &item.session,
            &record,
            &profile_match,
            &status,
            &refreshed_at,
        );
        match_records.push(archive_match_record(
            &archive_key,
            &item.session,
            &profile_match,
        ));
        index_records.push(index_record);
        upsert_conversation_record(&mut conversations, record.clone());
        written.push(record);
    }

    append_preserved_index_records(&previous_index, &current_keys, &mut index_records);
    index_records.sort_by(|left, right| {
        left.get("archive_key")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                right
                    .get("archive_key")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });
    write_jsonl(
        &collection_dir.join(CONVERSATION_INDEX_JSONL),
        &index_records,
    )?;
    conversations.retain(|record| {
        !record
            .get("sourcePath")
            .and_then(Value::as_str)
            .map(excluded_archive_source_path)
            .unwrap_or(false)
    });
    prune_excluded_unindexed_snapshots(&collection_dir, &index_records)?;
    write_jsonl(&collection_dir.join(MATCHES_JSONL), &match_records)?;
    atomic_write_json(
        &collection_dir.join(SOURCES_JSON),
        &json!({
            "schemaVersion": COLLECTION_SCHEMA_VERSION,
            "profileId": profile.profile_id,
            "collectionPathSegments": profile.collection_path_segments,
            "generatedAt": refreshed_at,
            "agents": discovery.agents,
            "sources": discovery.source_summaries,
            "diagnostics": discovery.diagnostics
        }),
    )?;

    let validation = validate_archive_collection(&collection_dir, &index_records, &profile)?;
    atomic_write_json(&collection_dir.join(VALIDATION_JSON), &validation)?;
    atomic_write_text(
        &collection_dir.join(CONVERSATION_INDEX_MD),
        &conversation_index_markdown(&profile, &index_records, &validation),
    )?;
    atomic_write_text(
        &collection_dir.join(SUMMARY_MD),
        &archive_summary_markdown(&profile, &root, &discovery, &index_records, &validation),
    )?;

    let workflow_diagnostics =
        archive_workflow_diagnostics(&discovery, &validation, index_records.len());
    let status = if index_records.is_empty() {
        "empty"
    } else {
        "materialized"
    };
    let collection = build_collection(
        &existing,
        &profile.display_name,
        &profile.profile_id,
        &root,
        status,
        conversations,
        &refreshed_at,
        &discovery.source_summaries,
        &workflow_diagnostics,
        &curation,
        written.len(),
        discovery.candidates.len(),
    );
    let mut collection_object = collection.as_object().cloned().unwrap_or_default();
    collection_object.insert("kind".to_string(), json!("native-conversation-archive"));
    collection_object.insert(
        "archiveProfile".to_string(),
        archive_profile_value(&profile),
    );
    collection_object.insert("archiveHealth".to_string(), validation.clone());
    atomic_write_json(&collection_path, &Value::Object(collection_object))?;

    let trigger = text_param(params, &["trigger"]).unwrap_or_else(|| "manual".to_string());
    let activity = store.activity_log().append(
        "conversation_snapshots.archive_run",
        json!({
            "target": "conversation-snapshots",
            "entry": entry,
            "trigger": trigger,
            "profileId": profile.profile_id,
            "collectionPathSegments": profile.collection_path_segments,
            "snapshotRoot": display_path(&root),
            "collectionPath": display_path(&collection_path),
            "candidateCount": discovery.candidates.len(),
            "selectedCount": written.len(),
            "indexCount": index_records.len(),
            "healthStatus": validation.get("healthStatus").cloned().unwrap_or_else(|| json!("unknown")),
            "status": status
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": status,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "mode": "conversation-archive",
        "entry": entry,
        "profileId": profile.profile_id,
        "collectionPathSegments": profile.collection_path_segments,
        "displayName": profile.display_name,
        "snapshotRoot": display_path(&root),
        "collectionPath": display_path(&collection_path),
        "candidateCount": discovery.candidates.len(),
        "selectedCount": written.len(),
        "indexCount": index_records.len(),
        "written": written,
        "sourcesPath": display_path(&collection_dir.join(SOURCES_JSON)),
        "conversationIndexPath": display_path(&collection_dir.join(CONVERSATION_INDEX_JSONL)),
        "summaryPath": display_path(&collection_dir.join(SUMMARY_MD)),
        "curation": curation,
        "diagnostics": discovery.diagnostics,
        "validation": validation,
        "activity": activity
    }))
}

fn materialize_archive_work_items_parallel(
    collection_dir: &Path,
    topic: &str,
    topic_key: &str,
    refreshed_at: &str,
    work_items: Vec<ArchiveMaterializeWorkItem>,
    parallelism: usize,
) -> Result<Vec<ArchiveMaterializeResult>> {
    if work_items.is_empty() {
        return Ok(Vec::new());
    }
    let worker_count = parallelism.max(1).min(work_items.len());
    let chunk_size = work_items.len().div_ceil(worker_count);
    let mut results = Vec::<ArchiveMaterializeResult>::with_capacity(work_items.len());

    thread::scope(|scope| -> Result<()> {
        let mut handles = Vec::new();
        for chunk in work_items.chunks(chunk_size) {
            let chunk = chunk.to_vec();
            handles.push(
                scope.spawn(move || -> Result<Vec<ArchiveMaterializeResult>> {
                    let mut chunk_results =
                        Vec::<ArchiveMaterializeResult>::with_capacity(chunk.len());
                    for item in chunk {
                        let archive_key = archive_key_for_session(&item.selected.session);
                        let record = materialize_snapshot(
                            collection_dir,
                            topic,
                            topic_key,
                            &item.selected,
                            refreshed_at,
                        )?;
                        chunk_results.push(ArchiveMaterializeResult {
                            position: item.position,
                            archive_key,
                            session: item.selected.session,
                            profile_match: item.profile_match,
                            record,
                        });
                    }
                    Ok(chunk_results)
                }),
            );
        }
        for handle in handles {
            match handle.join() {
                Ok(Ok(mut chunk_results)) => results.append(&mut chunk_results),
                Ok(Err(error)) => return Err(error),
                Err(_) => return Err(anyhow!("archive materialize worker panicked")),
            }
        }
        Ok(())
    })?;

    Ok(results)
}

fn archive_parallelism(params: &Value) -> usize {
    if let Some(value) = usize_param(params, &["archiveParallelism", "parallelism"]) {
        return value.max(1);
    }
    thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(4)
        .clamp(1, 8)
}

pub fn archive_verify(params: &Value) -> Result<Value> {
    if text_param(params, &["collectionPath", "collection", "path"])
        .filter(|value| !value.trim().is_empty())
        .is_some()
    {
        return archive_verify_collection_path(params);
    }
    let store = client_state_store(params)?;
    let profile = load_archive_profile(&store, params)?;
    let root = archive_root_for_profile(&store, params, &profile)?;
    let collection_dir = collection_dir_for_profile(&root, &profile);
    let index_records = read_index_records(&collection_dir.join(CONVERSATION_INDEX_JSONL))?;
    let validation = validate_archive_collection(&collection_dir, &index_records, &profile)?;
    atomic_write_json(&collection_dir.join(VALIDATION_JSON), &validation)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "mode": "conversation-archive-verify",
        "profileId": profile.profile_id,
        "collectionPathSegments": profile.collection_path_segments,
        "collectionPath": display_path(&collection_dir.join(COLLECTION_JSON)),
        "validation": validation
    }))
}

fn archive_verify_collection_path(params: &Value) -> Result<Value> {
    let raw_path = text_param(params, &["collectionPath", "collection", "path"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("archive verify requires --collection-path"))?;
    let requested = expand_home(&raw_path);
    let collection_path = if requested.is_dir() {
        requested.join(COLLECTION_JSON)
    } else {
        requested.clone()
    };
    let collection_dir = collection_path
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| anyhow!("archive collection path has no parent directory"))?;
    let collection = read_json_or_default(&collection_path, || json!({}))?;
    let profile_value = collection
        .get("archiveProfile")
        .cloned()
        .ok_or_else(|| anyhow!("archive collection is missing archiveProfile"))?;
    let profile = parse_archive_profile(&profile_value)?;
    let index_records = read_index_records(&collection_dir.join(CONVERSATION_INDEX_JSONL))?;
    let validation = validate_archive_collection(&collection_dir, &index_records, &profile)?;
    atomic_write_json(&collection_dir.join(VALIDATION_JSON), &validation)?;
    let mut updated_collection = collection.as_object().cloned().unwrap_or_default();
    updated_collection.insert("archiveHealth".to_string(), validation.clone());
    updated_collection.insert("refreshedAt".to_string(), json!(timestamp_rfc3339()));
    atomic_write_json(&collection_path, &Value::Object(updated_collection))?;
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "mode": "conversation-archive-verify",
        "profileId": profile.profile_id,
        "collectionPathSegments": profile.collection_path_segments,
        "collectionPath": display_path(&collection_path),
        "validation": validation
    }))
}

pub fn archive_report(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let profile = load_archive_profile(&store, params)?;
    let root = archive_root_for_profile(&store, params, &profile)?;
    let collection_dir = collection_dir_for_profile(&root, &profile);
    let collection = read_json_or_default(&collection_dir.join(COLLECTION_JSON), || json!({}))?;
    let validation = read_json_or_default(&collection_dir.join(VALIDATION_JSON), || json!({}))?;
    let sources = read_json_or_default(&collection_dir.join(SOURCES_JSON), || json!({}))?;
    let index_records = read_index_records(&collection_dir.join(CONVERSATION_INDEX_JSONL))?;
    Ok(json!({
        "ok": true,
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "mode": "conversation-archive-report",
        "profileId": profile.profile_id,
        "collectionPathSegments": profile.collection_path_segments,
        "displayName": profile.display_name,
        "snapshotRoot": display_path(&root),
        "collectionPath": display_path(&collection_dir.join(COLLECTION_JSON)),
        "conversationIndexPath": display_path(&collection_dir.join(CONVERSATION_INDEX_JSONL)),
        "summaryPath": display_path(&collection_dir.join(SUMMARY_MD)),
        "indexCount": index_records.len(),
        "collection": collection_summary(&collection, &collection_dir.join(COLLECTION_JSON)),
        "validation": validation,
        "sources": sources
    }))
}

pub fn archive_collect(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let keywords = archive_keywords(params)?;
    let archive_root = archive_destination(params)?;
    let target_scan = archive_target_scan(params)?;
    let agents = archive_agents_from_target_scan(params, &target_scan);
    if agents.is_empty() {
        return Ok(json!({
            "ok": false,
            "status": "no_supported_clients_detected",
            "mode": "conversation-archive",
            "entry": "keyword-archive",
            "keywords": keywords,
            "archiveRoot": display_path(&archive_root),
            "message": "No supported local agent clients were detected for conversation archive.",
            "targetScan": archive_target_scan_summary(&target_scan, &[])
        }));
    }
    let profiles = derived_keyword_archive_profiles(&keywords, &archive_root, &agents)?;
    let run_params = merge_params(
        params,
        json!({
            "archiveRoot": display_path(&archive_root),
            "agents": agents.join(","),
            "targetScan": target_scan
        }),
    );
    let mut keyword_runs =
        run_keyword_archives_parallel(&store, &run_params, &keywords, profiles, &archive_root)?;
    keyword_runs.sort_by_key(|item| item.position);
    let mut archives = Vec::<Value>::new();
    let mut total_index_count = 0_u64;
    let mut total_selected_count = 0_u64;
    let mut failed_count = 0_u64;
    for keyword_run in keyword_runs {
        let run = keyword_run.run;
        let folder_name = run
            .get("collectionPathSegments")
            .and_then(Value::as_array)
            .and_then(|segments| segments.first())
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| {
                run.get("profileId")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_default();
        let validation = run.get("validation").cloned().unwrap_or_else(|| json!({}));
        let health = validation
            .get("healthStatus")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let index_count = run.get("indexCount").and_then(Value::as_u64).unwrap_or(0);
        let selected_count = run
            .get("selectedCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        total_index_count += index_count;
        total_selected_count += selected_count;
        if health == "failed" {
            failed_count += 1;
        }
        let archive_status = if health == "failed" {
            "failed"
        } else if index_count == 0 {
            "empty"
        } else {
            "archived"
        };
        archives.push(json!({
            "keyword": keyword_run.keyword,
            "folderName": folder_name,
            "status": archive_status,
            "profileId": run.get("profileId").cloned().unwrap_or_else(|| json!("")),
            "collectionPathSegments": run.get("collectionPathSegments").cloned().unwrap_or_else(|| json!([])),
            "folderPath": run.get("collectionPath")
                .and_then(Value::as_str)
                .and_then(|path| Path::new(path).parent().map(display_path))
                .map(Value::String)
                .unwrap_or_else(|| json!("")),
            "collectionPath": run.get("collectionPath").cloned().unwrap_or_else(|| json!("")),
            "documentCount": index_count,
            "selectedCount": selected_count,
            "documents": {
                "summary": run.get("summaryPath").cloned().unwrap_or_else(|| json!("")),
                "conversationIndex": run.get("conversationIndexPath").cloned().unwrap_or_else(|| json!("")),
                "collection": run.get("collectionPath").cloned().unwrap_or_else(|| json!(""))
            },
            "healthStatus": health,
            "validation": validation
        }));
    }
    let ok = failed_count == 0;
    let status = if !ok {
        if total_index_count == 0 {
            "failed"
        } else {
            "partial_failed"
        }
    } else if total_index_count == 0 {
        "empty"
    } else {
        "archived"
    };
    let first_archive = archives.first().cloned().unwrap_or_else(|| json!({}));
    let collection_path = if archives.len() == 1 {
        first_archive
            .get("collectionPath")
            .cloned()
            .unwrap_or_else(|| json!(""))
    } else {
        json!(display_path(&archive_root))
    };
    let archive_count = archives.len();
    let collection_path_segments = if archive_count == 1 {
        first_archive
            .get("collectionPathSegments")
            .cloned()
            .unwrap_or_else(|| json!([]))
    } else {
        Value::Array(
            archives
                .iter()
                .filter_map(|archive| archive.get("collectionPathSegments").cloned())
                .collect::<Vec<_>>(),
        )
    };
    let documents = if archive_count == 1 {
        first_archive
            .get("documents")
            .cloned()
            .unwrap_or_else(|| json!({}))
    } else {
        json!({
            "root": display_path(&archive_root)
        })
    };
    Ok(json!({
        "ok": ok,
        "status": status,
        "mode": "conversation-archive",
        "entry": "keyword-archive",
        "keywords": keywords,
        "keywordCount": archive_count,
        "collectionPathSegments": collection_path_segments,
        "archiveRoot": display_path(&archive_root),
        "collectionPath": collection_path,
        "documentCount": total_index_count,
        "selectedCount": total_selected_count,
        "archives": archives,
        "documents": documents,
        "message": if ok {
            format!(
                "Archived {} native conversations into {} keyword folders.",
                total_selected_count,
                archive_count
            )
        } else {
            "Conversation archive validation failed.".to_string()
        },
        "targetScan": archive_target_scan_summary(&target_scan, &agents)
    }))
}

pub fn collect(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let topic = text_param(params, &["topic", "project", "intent"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshots collect requires --topic"))?;
    let topic_key = topic_key(&topic)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("snapshot topic is empty after normalization"))?;
    let root = snapshot_root(&store, params)?;
    let mut raw = Map::<String, Value>::new();
    raw.insert("profileId".to_string(), json!(topic_key));
    raw.insert("displayName".to_string(), json!(topic));
    raw.insert("canonicalNames".to_string(), json!([topic.clone()]));
    raw.insert("aliasNames".to_string(), json!([]));
    raw.insert("projectPaths".to_string(), json!([]));
    raw.insert(
        "expectedAgents".to_string(),
        json!(collect_agent_ids(params)),
    );
    raw.insert("expectedSources".to_string(), json!([]));
    raw.insert("exclusionRules".to_string(), json!([]));
    let profile = parse_archive_profile(&Value::Object(raw))?;
    let mut result = run_archive_with_profile(&store, params, profile, root.path, "collect")?;
    if let Some(object) = result.as_object_mut() {
        object.insert("topic".to_string(), json!(topic));
        object.insert("topicKey".to_string(), json!(topic_key));
    }
    Ok(result)
}

pub fn bridge_ensure(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let target = text_param(params, &["target", "agent", "agentId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshots bridge ensure requires --target"))?;
    let config_path = text_param(params, &["configPath"])
        .map(|value| expand_home(&value))
        .or_else(|| default_target_config_path(&target));
    let Some(config_path) = config_path else {
        return Ok(json!({
            "ok": false,
            "status": "config_path_required",
            "target": target,
            "message": "A target config path is needed before the snapshot curation bridge can be recorded."
        }));
    };

    let current = fs::read_to_string(&config_path).unwrap_or_default();
    let bridge = bridge_config(&target);
    let new_content = apply_bridge_config(&config_path, &current, &bridge, params)?;
    let snapshot = store.snapshot_store().capture(
        &target,
        &config_path,
        json!({
            "operation": "snapshots.bridge.ensure",
            "target": target,
            "configPath": display_path(&config_path)
        }),
    )?;
    atomic_write_text(&config_path, &new_content)?;
    let verified = verify_bridge_config(&config_path)?;
    let state = json!({
        "target": target,
        "bridgeId": bridge.get("bridgeId").cloned().unwrap_or_else(|| json!("")),
        "status": if verified { "verified" } else { "unverified" },
        "configPath": display_path(&config_path),
        "snapshotId": snapshot.snapshot_id,
        "snapshotPath": display_path(&snapshot.snapshot_path),
        "verifiedAt": timestamp_rfc3339(),
        "tools": bridge.get("tools").cloned().unwrap_or_else(|| json!([]))
    });
    upsert_bridge_state(&store, &target, state.clone())?;
    let activity = store.activity_log().append(
        "conversation_snapshots.bridge_ensured",
        json!({
            "target": target,
            "configPath": display_path(&config_path),
            "bridgeId": state.get("bridgeId").cloned().unwrap_or_else(|| json!("")),
            "status": state.get("status").cloned().unwrap_or_else(|| json!(""))
        }),
    )?;
    Ok(json!({
        "ok": verified,
        "status": if verified { "verified" } else { "unverified" },
        "target": target,
        "bridge": state,
        "activity": activity
    }))
}

pub fn curation_start(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let topic = text_param(params, &["topic", "project", "intent"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshots curation start requires --topic"))?;
    let topic_key = topic_key(&topic)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("snapshot topic is empty after normalization"))?;
    let discovery = discover_candidates(&store, params);
    let session_id = format!(
        "curation-{}-{}",
        timestamp_stamp(),
        &hash_text(&(topic_key.clone() + &timestamp_stamp()))[..12]
    );
    let created_at = timestamp_rfc3339();
    let read_budget = text_param(params, &["readBudget", "readBudgetItems"])
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(12);
    let (session, path) = create_curation_session(
        &store,
        &session_id,
        &topic,
        &topic_key,
        &created_at,
        read_budget,
        &discovery,
    )?;
    let activity = store.activity_log().append(
        "conversation_snapshots.curation_session_started",
        json!({
            "target": "conversation-snapshots",
            "topic": session.get("topic").cloned().unwrap_or_else(|| json!("")),
            "curationSessionId": session.get("curationSessionId").cloned().unwrap_or_else(|| json!("")),
            "candidateCount": session.get("candidateBriefs").and_then(Value::as_array).map(Vec::len).unwrap_or(0)
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "started",
        "curationSessionId": session.get("curationSessionId").cloned().unwrap_or_else(|| json!("")),
        "topic": session.get("topic").cloned().unwrap_or_else(|| json!("")),
        "topicKey": session.get("topicKey").cloned().unwrap_or_else(|| json!("")),
        "candidateCount": session.get("candidateBriefs").and_then(Value::as_array).map(Vec::len).unwrap_or(0),
        "readBudget": read_budget,
        "sessionPath": display_path(&path),
        "candidateBriefs": session.get("candidateBriefs").cloned().unwrap_or_else(|| json!([])),
        "activity": activity
    }))
}

pub fn curation_candidates_list(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let mut session = load_curation_session(&store, params)?;
    let session_id = text_value(&session, "curationSessionId").unwrap_or_default();
    let briefs = session
        .get("candidateBriefs")
        .cloned()
        .unwrap_or_else(|| json!([]));
    session["lastListedAt"] = json!(timestamp_rfc3339());
    atomic_write_json(&curation_session_path(&store, &session_id)?, &session)?;
    Ok(json!({
        "ok": true,
        "status": "listed",
        "curationSessionId": session_id,
        "candidateBriefs": briefs,
        "remainingExpansions": session.get("remainingExpansions").cloned().unwrap_or_else(|| json!(0)),
        "acceptedResultShape": session.get("acceptedResultShape").cloned().unwrap_or_else(|| json!({}))
    }))
}

pub fn curation_candidate_expand(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let mut session = load_curation_session(&store, params)?;
    let session_id = text_value(&session, "curationSessionId").unwrap_or_default();
    let candidate_id_param = text_param(params, &["candidateId", "id"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshot curation expand requires --candidate-id"))?;
    let remaining = session
        .get("remainingExpansions")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if remaining == 0 {
        return Ok(json!({
            "ok": false,
            "status": "read_budget_exhausted",
            "curationSessionId": session_id,
            "candidateId": candidate_id_param
        }));
    }
    let candidate = session
        .get("candidates")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| candidate_id(item).as_deref() == Some(candidate_id_param.as_str()))
                .cloned()
        })
        .ok_or_else(|| anyhow!("unknown curation candidate id: {}", candidate_id_param))?;
    session["remainingExpansions"] = json!(remaining - 1);
    session["lastExpandedAt"] = json!(timestamp_rfc3339());
    atomic_write_json(&curation_session_path(&store, &session_id)?, &session)?;
    Ok(json!({
        "ok": true,
        "status": "expanded",
        "curationSessionId": session_id,
        "candidateId": candidate_id_param,
        "remainingExpansions": remaining - 1,
        "candidate": candidate
    }))
}

pub fn curation_submit_result(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let mut session = load_curation_session(&store, params)?;
    let session_id = text_value(&session, "curationSessionId").unwrap_or_default();
    let result = curation_result(params)?
        .ok_or_else(|| anyhow!("snapshot curation submit-result requires a structured result"))?;
    validate_curation_result_for_session(&session, &result)?;
    session["submittedResult"] = result.clone();
    session["submittedAt"] = json!(timestamp_rfc3339());
    atomic_write_json(&curation_session_path(&store, &session_id)?, &session)?;
    Ok(json!({
        "ok": true,
        "status": "submitted",
        "curationSessionId": session_id,
        "submittedResult": result
    }))
}

fn create_curation_session(
    store: &ClientStateStore,
    session_id: &str,
    topic: &str,
    topic_key: &str,
    created_at: &str,
    read_budget: usize,
    discovery: &DiscoveryResult,
) -> Result<(Value, PathBuf)> {
    let session = json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "kind": "snapshot-curation-tool-session",
        "curationSessionId": session_id,
        "topic": topic,
        "topicKey": topic_key,
        "agents": discovery.agents.clone(),
        "createdAt": created_at,
        "expiresAt": "task-scoped",
        "readBudget": read_budget,
        "remainingExpansions": read_budget,
        "acceptedResultShape": {
            "selectedCandidateIds": "string[]",
            "rejectedCandidateIds": "string[]",
            "labelsByCandidateId": "Record<string,string[]>",
            "groupsByCandidateId": "Record<string,string>",
            "summariesByCandidateId": "Record<string,string>",
            "reasonsByCandidateId": "Record<string,string>"
        },
        "candidates": discovery.candidates.clone(),
        "candidateBriefs": discovery.candidates.iter().map(candidate_brief).collect::<Vec<_>>(),
        "sources": discovery.source_summaries.clone(),
        "diagnostics": discovery.diagnostics.clone(),
        "submittedResult": null
    });
    let path = curation_session_path(store, session_id)?;
    atomic_write_json(&path, &session)?;
    Ok((session, path))
}

fn snapshot_root(store: &ClientStateStore, params: &Value) -> Result<SnapshotRoot> {
    if let Some(root) = text_param(params, &["snapshotRoot"]) {
        if !root.trim().is_empty() {
            return Ok(SnapshotRoot {
                path: expand_home(&root),
                mode: "override",
            });
        }
    }
    let settings = store.read_collection(SETTINGS_COLLECTION)?;
    for key in ["conversationSnapshotRoot", "snapshotRoot"] {
        if let Some(root) = settings.get(key).and_then(Value::as_str) {
            if !root.trim().is_empty() {
                return Ok(SnapshotRoot {
                    path: expand_home(root),
                    mode: "user-controlled",
                });
            }
        }
    }
    Ok(SnapshotRoot {
        path: store.root().join(DEFAULT_SNAPSHOT_ROOT_DIR),
        mode: "default",
    })
}

fn write_snapshot_root_setting(store: &ClientStateStore, root: &Path) -> Result<()> {
    let mut settings = store
        .read_collection(SETTINGS_COLLECTION)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    settings.insert(
        "conversationSnapshotRoot".to_string(),
        json!(display_path(root)),
    );
    store.write_collection(SETTINGS_COLLECTION, Value::Object(settings))?;
    Ok(())
}

fn curation_session_path(store: &ClientStateStore, session_id: &str) -> Result<PathBuf> {
    let clean = sanitize_id(session_id);
    if clean.is_empty() {
        return Err(anyhow!("curation session id is empty"));
    }
    Ok(store
        .root()
        .join("snapshot-curation-sessions")
        .join(format!("{}.json", clean)))
}

fn load_curation_session(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let session_id = text_param(params, &["curationSessionId", "sessionId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("snapshot curation tool requires --curation-session-id"))?;
    let path = curation_session_path(store, &session_id)?;
    if !path.exists() {
        return Err(anyhow!("unknown snapshot curation session: {}", session_id));
    }
    let session = read_json_or_default(&path, || json!({}))?;
    if session.get("kind").and_then(Value::as_str) != Some("snapshot-curation-tool-session") {
        return Err(anyhow!("invalid snapshot curation session: {}", session_id));
    }
    Ok(session)
}

fn load_curation_session_by_id(store: &ClientStateStore, session_id: &str) -> Result<Value> {
    let path = curation_session_path(store, session_id)?;
    if !path.exists() {
        return Err(anyhow!("unknown snapshot curation session: {}", session_id));
    }
    let session = read_json_or_default(&path, || json!({}))?;
    if session.get("kind").and_then(Value::as_str) != Some("snapshot-curation-tool-session") {
        return Err(anyhow!("invalid snapshot curation session: {}", session_id));
    }
    Ok(session)
}

fn curation_session_submitted_result(
    store: &ClientStateStore,
    params: &Value,
) -> Result<Option<(String, Value)>> {
    let Some(session_id) = text_param(params, &["curationSessionId", "sessionId"])
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(None);
    };
    let session = load_curation_session(store, params)?;
    let result = session
        .get("submittedResult")
        .filter(|value| !value.is_null())
        .cloned();
    Ok(result.map(|result| (session_id, result)))
}

fn candidate_brief(candidate: &Value) -> Value {
    let preview = candidate
        .get("messages")
        .and_then(Value::as_array)
        .and_then(|messages| {
            messages
                .iter()
                .filter_map(|message| message.get("text").and_then(Value::as_str))
                .find(|text| !text.trim().is_empty())
        })
        .map(|text| truncate_chars(text, 320))
        .unwrap_or_default();
    json!({
        "candidateId": candidate.get("id").cloned().unwrap_or_else(|| json!("")),
        "title": candidate.get("title").cloned().unwrap_or_else(|| json!("Native agent history")),
        "agentId": candidate.get("agentId").cloned().unwrap_or_else(|| json!("")),
        "adapterId": candidate.get("adapterId").cloned().unwrap_or_else(|| json!("")),
        "nativeSessionId": candidate.get("nativeSessionId").cloned().unwrap_or_else(|| json!("")),
        "sourceKind": candidate.get("sourceKind").cloned().unwrap_or_else(|| json!("")),
        "sourcePath": candidate.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "messageCount": candidate.get("messageCount").cloned().unwrap_or_else(|| json!(0)),
        "updatedAt": candidate.get("updatedAt").cloned().unwrap_or_else(|| json!("")),
        "preview": preview
    })
}

fn validate_curation_result_for_session(session: &Value, result: &Value) -> Result<()> {
    let mut known = BTreeSet::<String>::new();
    if let Some(candidates) = session.get("candidates").and_then(Value::as_array) {
        for candidate in candidates {
            if let Some(id) = candidate_id(candidate) {
                known.insert(id);
            }
        }
    }
    let selections = result
        .get("selectedCandidateIds")
        .or_else(|| result.get("selected"))
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("structured curation result requires selectedCandidateIds"))?;
    validate_candidate_id_array("selectedCandidateIds", selections, &known)?;
    if let Some(rejected) = result.get("rejectedCandidateIds").and_then(Value::as_array) {
        validate_candidate_id_array("rejectedCandidateIds", rejected, &known)?;
    }
    validate_string_array_map(result, "labelsByCandidateId", &known)?;
    validate_string_map(result, "groupsByCandidateId", &known)?;
    validate_string_map(result, "summariesByCandidateId", &known)?;
    validate_string_map(result, "reasonsByCandidateId", &known)?;
    Ok(())
}

fn validate_candidate_id_array(
    field: &str,
    items: &[Value],
    known: &BTreeSet<String>,
) -> Result<()> {
    for value in items {
        let Some(id) = value.as_str() else {
            return Err(anyhow!("{} entries must be strings", field));
        };
        if !known.contains(id) {
            return Err(anyhow!("{} contains unknown candidate id: {}", field, id));
        }
    }
    Ok(())
}

fn validate_string_array_map(result: &Value, field: &str, known: &BTreeSet<String>) -> Result<()> {
    let Some(object) = result.get(field).and_then(Value::as_object) else {
        return Ok(());
    };
    for (candidate_id, value) in object {
        if !known.contains(candidate_id) {
            return Err(anyhow!(
                "{} contains unknown candidate id: {}",
                field,
                candidate_id
            ));
        }
        let Some(items) = value.as_array() else {
            return Err(anyhow!("{} values must be string arrays", field));
        };
        if items.iter().any(|item| item.as_str().is_none()) {
            return Err(anyhow!("{} values must be string arrays", field));
        }
    }
    Ok(())
}

fn validate_string_map(result: &Value, field: &str, known: &BTreeSet<String>) -> Result<()> {
    let Some(object) = result.get(field).and_then(Value::as_object) else {
        return Ok(());
    };
    for (candidate_id, value) in object {
        if !known.contains(candidate_id) {
            return Err(anyhow!(
                "{} contains unknown candidate id: {}",
                field,
                candidate_id
            ));
        }
        if value.as_str().is_none() {
            return Err(anyhow!("{} values must be strings", field));
        }
    }
    Ok(())
}

fn ensure_snapshot_root(root: &Path) -> Result<()> {
    fs::create_dir_all(root.join("collections"))?;
    let marker_path = root.join(MARKER_FILE);
    if !marker_path.exists() {
        atomic_write_json(
            &marker_path,
            &json!({
                "schemaVersion": COLLECTION_SCHEMA_VERSION,
                "kind": "lico-native-conversation-snapshot-root",
                "createdAt": timestamp_rfc3339()
            }),
        )?;
    }
    Ok(())
}

fn migrate_snapshot_root(old_root: &Path, new_root: &Path) -> Result<Value> {
    if let Some(parent) = new_root.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::rename(old_root, new_root) {
        Ok(()) => Ok(json!({
            "status": "migrated",
            "method": "rename",
            "from": display_path(old_root),
            "to": display_path(new_root)
        })),
        Err(_) => {
            copy_dir_all(old_root, new_root)?;
            fs::remove_dir_all(old_root)?;
            Ok(json!({
                "status": "migrated",
                "method": "copy",
                "from": display_path(old_root),
                "to": display_path(new_root)
            }))
        }
    }
}

fn collect_agent_ids(params: &Value) -> Vec<String> {
    if let Some(agent) = text_param(params, &["agent", "agentId", "target"]) {
        if !agent.trim().is_empty() {
            return vec![agent];
        }
    }
    if let Some(agents) = params.get("agents").and_then(Value::as_str) {
        let list = agents
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        if !list.is_empty() {
            return list;
        }
    }
    SUPPORTED_AGENTS
        .iter()
        .map(|value| value.to_string())
        .collect()
}

fn explicit_agent_ids(params: &Value) -> Vec<String> {
    if text_param(params, &["agent", "agentId", "target"])
        .filter(|agent| !agent.trim().is_empty())
        .is_some()
        || params
            .get("agents")
            .and_then(Value::as_str)
            .filter(|agents| !agents.trim().is_empty())
            .is_some()
    {
        return collect_agent_ids(params)
            .into_iter()
            .map(|agent| normalize_agent_alias(&agent))
            .filter(|agent| SUPPORTED_AGENTS.contains(&agent.as_str()))
            .collect();
    }
    Vec::new()
}

fn archive_keywords(params: &Value) -> Result<Vec<String>> {
    let mut seen_normalized = BTreeSet::<String>::new();
    let mut keywords = Vec::<String>::new();
    for key in ["keywords", "keyword", "terms", "query", "topic"] {
        let mut raw_keywords = Vec::<String>::new();
        match params.get(key) {
            Some(Value::Array(items)) => {
                for item in items {
                    if let Some(text) = item.as_str() {
                        raw_keywords.extend(split_keyword_list(text));
                    }
                }
            }
            Some(Value::String(text)) => raw_keywords.extend(split_keyword_list(text)),
            _ => {}
        }
        for keyword in raw_keywords {
            let normalized = normalize_match_text(&keyword);
            if !normalized.trim_matches('-').is_empty() && seen_normalized.insert(normalized) {
                keywords.push(keyword);
            }
        }
        if !keywords.is_empty() {
            break;
        }
    }
    if keywords.is_empty() {
        return Err(anyhow!("archive collect requires --keywords"));
    }
    Ok(keywords)
}

fn split_keyword_list(value: &str) -> Vec<String> {
    value
        .split([',', '\n'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn archive_destination(params: &Value) -> Result<PathBuf> {
    let raw = text_param(
        params,
        &[
            "path",
            "archiveRoot",
            "destination",
            "destinationPath",
            "outputDir",
            "snapshotRoot",
        ],
    )
    .filter(|value| !value.trim().is_empty())
    .ok_or_else(|| anyhow!("archive collect requires --path"))?;
    let expanded = expand_home(&raw);
    // Reject path traversal components.
    ensure!(
        !expanded.to_string_lossy().contains(".."),
        "archive destination path must not contain traversal components"
    );
    // Canonicalize if the path exists, otherwise canonicalize the parent.
    let canonical = if expanded.exists() {
        expanded.canonicalize()?
    } else if let Some(parent) = expanded.parent() {
        if !parent.exists() {
            return Err(anyhow!(
                "archive destination parent does not exist: {}",
                parent.display()
            ));
        }
        let canonical_parent = parent.canonicalize()?;
        canonical_parent.join(
            expanded
                .file_name()
                .ok_or_else(|| anyhow!("archive destination has no file name"))?,
        )
    } else {
        return Err(anyhow!(
            "archive destination cannot be canonicalized: {}",
            expanded.display()
        ));
    };
    // Reject destinations not owned by the current user.
    crate::platform::file_security::validate_export_destination(&canonical)?;
    Ok(canonical)
}

fn archive_target_scan(params: &Value) -> Result<Value> {
    if let Some(value) = params.get("targetScan").filter(|value| value.is_object()) {
        return Ok(value.clone());
    }
    if let Some(raw) = text_param(params, &["targetScanJson"]) {
        return Ok(serde_json::from_str(&raw)?);
    }
    if let Some(path) = text_param(params, &["targetScanFile"]) {
        let path = expand_home(&path);
        return read_json_or_default(&path, || json!({ "candidates": [] }));
    }
    targets::scan_targets_with_params(params)
}

fn archive_agents_from_target_scan(params: &Value, target_scan: &Value) -> Vec<String> {
    let explicit = explicit_agent_ids(params);
    if !explicit.is_empty() {
        return unique_agents(explicit);
    }
    let mut agents = Vec::<String>::new();
    for candidate in target_scan
        .get("candidates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        let target = candidate
            .get("target")
            .and_then(Value::as_str)
            .map(normalize_agent_alias)
            .unwrap_or_default();
        if !SUPPORTED_AGENTS.contains(&target.as_str()) {
            continue;
        }
        let status = candidate
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let has_history_roots = candidate
            .get("historyRoots")
            .and_then(Value::as_array)
            .map(|items| !items.is_empty())
            .unwrap_or(false);
        if status == "configured" || status == "detected" || status == "manual" || has_history_roots
        {
            agents.push(target);
        }
    }
    unique_agents(agents)
}

fn unique_agents(agents: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::<String>::new();
    let mut unique = Vec::<String>::new();
    for agent in agents {
        let normalized = normalize_agent_alias(&agent);
        if SUPPORTED_AGENTS.contains(&normalized.as_str()) && seen.insert(normalized.clone()) {
            unique.push(normalized);
        }
    }
    unique
}

fn archive_target_scan_summary(target_scan: &Value, selected_agents: &[String]) -> Value {
    let selected = selected_agents.iter().cloned().collect::<BTreeSet<_>>();
    let mut clients = Vec::<Value>::new();
    for candidate in target_scan
        .get("candidates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        let target = candidate
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let normalized = normalize_agent_alias(&target);
        let included = selected.contains(&normalized);
        clients.push(json!({
            "target": target,
            "label": candidate.get("label").cloned().unwrap_or_else(|| json!("")),
            "status": candidate.get("status").cloned().unwrap_or_else(|| json!("")),
            "included": included
        }));
    }
    json!({
        "source": target_scan.get("source").cloned().unwrap_or_else(|| json!("target-adapters")),
        "clientCount": clients.len(),
        "includedAgents": selected_agents,
        "clients": clients
    })
}

fn derived_archive_profile(
    keywords: &[String],
    archive_root: &Path,
    agents: &[String],
) -> Result<ArchiveProfile> {
    let archive_identity = archive_identity_for_keywords(keywords)?;
    let display_name = archive_identity.display_name;
    let collection_path_segments = archive_identity.collection_path_segments;
    let profile_id = archive_identity.profile_id;
    let canonical_names = archive_identity.canonical_names;
    let alias_names = archive_identity.alias_names;
    let raw = json!({
        "profileId": profile_id,
        "displayName": display_name,
        "collectionPathSegments": collection_path_segments,
        "archiveRoot": display_path(archive_root),
        "canonicalNames": canonical_names,
        "aliasNames": alias_names,
        "projectPaths": [],
        "expectedAgents": agents,
        "expectedSources": [],
        "exclusionRules": []
    });
    parse_archive_profile(&raw)
}

fn derived_keyword_archive_profiles(
    keywords: &[String],
    archive_root: &Path,
    agents: &[String],
) -> Result<Vec<ArchiveProfile>> {
    keywords
        .iter()
        .map(|keyword| derived_archive_profile(std::slice::from_ref(keyword), archive_root, agents))
        .collect()
}

fn run_keyword_archives_parallel(
    store: &ClientStateStore,
    params: &Value,
    keywords: &[String],
    profiles: Vec<ArchiveProfile>,
    archive_root: &Path,
) -> Result<Vec<KeywordArchiveRun>> {
    if profiles.is_empty() {
        return Ok(Vec::new());
    }
    let worker_count = archive_parallelism(params).max(1).min(profiles.len());
    let mut items = keywords
        .iter()
        .cloned()
        .zip(profiles)
        .enumerate()
        .collect::<Vec<_>>();
    let chunk_size = items.len().div_ceil(worker_count);
    let mut runs = Vec::<KeywordArchiveRun>::with_capacity(items.len());

    thread::scope(|scope| -> Result<()> {
        let mut handles = Vec::new();
        for chunk in items.chunks_mut(chunk_size) {
            let local_items = chunk.to_vec();
            let local_store = store.clone();
            let local_params = params.clone();
            let local_archive_root = archive_root.to_path_buf();
            handles.push(scope.spawn(move || -> Result<Vec<KeywordArchiveRun>> {
                let mut local_runs = Vec::<KeywordArchiveRun>::with_capacity(local_items.len());
                for (position, (keyword, profile)) in local_items {
                    let run = run_archive_with_profile_layout(
                        &local_store,
                        &local_params,
                        profile,
                        local_archive_root.clone(),
                        "keyword-archive",
                        ArchiveCollectionLayout::DirectKeywordFolders,
                    )?;
                    local_runs.push(KeywordArchiveRun {
                        position,
                        keyword,
                        run,
                    });
                }
                Ok(local_runs)
            }));
        }
        for handle in handles {
            let mut local_runs = handle
                .join()
                .map_err(|_| anyhow!("keyword archive worker panicked"))??;
            runs.append(&mut local_runs);
        }
        Ok(())
    })?;

    Ok(runs)
}

struct DerivedArchiveIdentity {
    profile_id: String,
    display_name: String,
    collection_path_segments: Vec<String>,
    canonical_names: Vec<String>,
    alias_names: Vec<String>,
}

fn archive_identity_for_keywords(keywords: &[String]) -> Result<DerivedArchiveIdentity> {
    let display_name = keywords.join(", ");
    let collection_path_segments = collection_path_segments_for_keywords(keywords)?;
    let profile_id = collection_path_segments.join("-").trim().to_string();
    if profile_id.is_empty() {
        return Err(anyhow!("archive keywords are empty after normalization"));
    }
    let profile_id = topic_key(&profile_id)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("archive keywords are empty after normalization"))?;
    Ok(DerivedArchiveIdentity {
        profile_id,
        display_name,
        collection_path_segments,
        canonical_names: keywords.to_vec(),
        alias_names: keyword_completion_aliases(keywords),
    })
}

fn collection_path_segments_for_keywords(keywords: &[String]) -> Result<Vec<String>> {
    let mut segments = Vec::<String>::new();
    let mut seen = BTreeSet::<String>::new();
    for keyword in keywords {
        let Some(segment) = topic_key(keyword) else {
            continue;
        };
        if !segment.is_empty() && seen.insert(segment.clone()) {
            segments.push(segment);
        }
    }
    if segments.is_empty() {
        Err(anyhow!("archive keywords are empty after normalization"))
    } else {
        Ok(segments)
    }
}

fn keyword_completion_aliases(keywords: &[String]) -> Vec<String> {
    let canonical_keys = keywords
        .iter()
        .map(|keyword| normalize_match_text(keyword))
        .collect::<BTreeSet<_>>();
    let mut aliases = BTreeMap::<String, String>::new();
    for keyword in keywords {
        let normalized = normalize_match_text(keyword);
        let compact = compact_identity_key(keyword);
        if !compact.is_empty() && compact != normalized && !canonical_keys.contains(&compact) {
            aliases.entry(compact.clone()).or_insert(compact);
        }
        let camel_spaced = split_camel_word(keyword);
        let camel_normalized = normalize_match_text(&camel_spaced);
        if !camel_normalized.is_empty()
            && camel_normalized != normalized
            && !canonical_keys.contains(&camel_normalized)
        {
            aliases.entry(camel_normalized).or_insert(camel_spaced);
        }
    }
    aliases.into_values().collect()
}

fn split_camel_word(value: &str) -> String {
    let mut out = String::new();
    let mut previous_lower_or_digit = false;
    for ch in value.chars() {
        if ch.is_uppercase() && previous_lower_or_digit && !out.ends_with(' ') {
            out.push(' ');
        }
        previous_lower_or_digit = ch.is_lowercase() || ch.is_ascii_digit();
        out.push(ch);
    }
    out
}

fn discover_candidates(store: &ClientStateStore, params: &Value) -> DiscoveryResult {
    let agents = collect_agent_ids(params);
    let mut candidates = Vec::<Value>::new();
    let mut source_summaries = Vec::<Value>::new();
    let mut diagnostics = Vec::<Value>::new();
    let mut seen_candidates = BTreeSet::<String>::new();
    for agent in &agents {
        let mut history_params = Map::<String, Value>::new();
        history_params.insert("agent".to_string(), json!(agent));
        if let Some(home_dir) = text_param(params, &["homeDir"]) {
            history_params.insert("homeDir".to_string(), json!(home_dir));
        }
        if let Some(archive_mode) = params.get("archiveMode") {
            history_params.insert("archiveMode".to_string(), archive_mode.clone());
        }
        match conversations::conversation_list(&Value::Object(history_params.clone())) {
            Ok(history) => {
                let sessions = history
                    .get("sessions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                extend_unique_candidates(&mut candidates, &mut seen_candidates, sessions);
                source_summaries.push(json!({
                    "agentId": agent,
                    "scope": "adapter-defaults",
                    "adapterId": history.get("adapterId").cloned().unwrap_or_else(|| json!(agent)),
                    "sessionCount": history.get("sessions").and_then(Value::as_array).map(Vec::len).unwrap_or(0),
                    "filesSeen": history.pointer("/sources/filesSeen").cloned().unwrap_or_else(|| json!(0)),
                    "skipped": history.pointer("/sources/skipped").cloned().unwrap_or_else(|| json!([]))
                }));
            }
            Err(error) => diagnostics.push(json!({
                "stage": "discovery",
                "agentId": agent,
                "status": "failed",
                "message": error.to_string()
            })),
        }

        match manual_history_roots(store, params, agent) {
            Ok(roots) => {
                for history_root in roots {
                    let mut manual_params = history_params.clone();
                    manual_params.insert(
                        "historyRoot".to_string(),
                        json!(display_path(&history_root)),
                    );
                    manual_params.insert(
                        "historyRootKind".to_string(),
                        json!("manual-target-history-root"),
                    );
                    match conversations::conversation_list(&Value::Object(manual_params)) {
                        Ok(history) => {
                            let sessions = history
                                .get("sessions")
                                .and_then(Value::as_array)
                                .cloned()
                                .unwrap_or_default();
                            let before = candidates.len();
                            extend_unique_candidates(
                                &mut candidates,
                                &mut seen_candidates,
                                sessions,
                            );
                            source_summaries.push(json!({
                                "agentId": agent,
                                "scope": "manual-target-history-root",
                                "historyRoot": display_path(&history_root),
                                "adapterId": history.get("adapterId").cloned().unwrap_or_else(|| json!(agent)),
                                "sessionCount": candidates.len().saturating_sub(before),
                                "filesSeen": history.pointer("/sources/filesSeen").cloned().unwrap_or_else(|| json!(0)),
                                "skipped": history.pointer("/sources/skipped").cloned().unwrap_or_else(|| json!([]))
                            }));
                        }
                        Err(error) => diagnostics.push(json!({
                            "stage": "discovery",
                            "agentId": agent,
                            "scope": "manual-target-history-root",
                            "historyRoot": display_path(&history_root),
                            "status": "failed",
                            "message": error.to_string()
                        })),
                    }
                }
            }
            Err(error) => diagnostics.push(json!({
                "stage": "discovery",
                "agentId": agent,
                "scope": "manual-target-history-root",
                "status": "failed",
                "message": error.to_string()
            })),
        }

        for remote_target in remote_history_targets(params, agent) {
            match mirror_remote_history(store, &remote_target) {
                Ok(mirror_home) => {
                    let mut remote_params = history_params.clone();
                    remote_params.insert("homeDir".to_string(), json!(display_path(&mirror_home)));
                    remote_params.insert(
                        "historyRootKind".to_string(),
                        json!("remote-target-history-root"),
                    );
                    match conversations::conversation_list(&Value::Object(remote_params)) {
                        Ok(history) => {
                            let sessions = history
                                .get("sessions")
                                .and_then(Value::as_array)
                                .cloned()
                                .unwrap_or_default();
                            let before = candidates.len();
                            extend_unique_candidates(
                                &mut candidates,
                                &mut seen_candidates,
                                sessions,
                            );
                            source_summaries.push(json!({
                                "agentId": agent,
                                "scope": "remote-target-history-root",
                                "targetCandidateId": remote_target.candidate_id,
                                "targetLabel": remote_target.label,
                                "location": remote_target.location,
                                "environment": {
                                    "id": remote_target.context_id,
                                    "name": remote_target.context_name,
                                    "user": remote_target.user
                                },
                                "mirrorRoot": display_path(&mirror_home),
                                "adapterId": history.get("adapterId").cloned().unwrap_or_else(|| json!(agent)),
                                "sessionCount": candidates.len().saturating_sub(before),
                                "filesSeen": history.pointer("/sources/filesSeen").cloned().unwrap_or_else(|| json!(0)),
                                "skipped": history.pointer("/sources/skipped").cloned().unwrap_or_else(|| json!([]))
                            }));
                        }
                        Err(error) => diagnostics.push(json!({
                            "stage": "discovery",
                            "agentId": agent,
                            "scope": "remote-target-history-root",
                            "targetCandidateId": remote_target.candidate_id,
                            "location": remote_target.location,
                            "status": "failed",
                            "message": error.to_string()
                        })),
                    }
                }
                Err(error) => diagnostics.push(json!({
                    "stage": "discovery",
                    "agentId": agent,
                    "scope": "remote-target-history-root",
                    "targetCandidateId": remote_target.candidate_id,
                    "location": remote_target.location,
                    "status": "failed",
                    "message": error.to_string()
                })),
            }
        }
    }
    DiscoveryResult {
        agents,
        candidates,
        source_summaries,
        diagnostics,
    }
}

fn discover_archive_candidates(
    store: &ClientStateStore,
    params: &Value,
    profile: &ArchiveProfile,
) -> DiscoveryResult {
    let agent_list = if profile.expected_agents.is_empty() {
        collect_agent_ids(params)
    } else {
        profile.expected_agents.clone()
    };
    let archive_params = merge_params(
        params,
        json!({
            "archiveMode": true,
            "agents": agent_list.join(","),
            "matchTerms": profile.canonical_names.iter().chain(profile.alias_names.iter()).cloned().collect::<Vec<_>>(),
            "matchProjectPaths": profile.project_paths.clone()
        }),
    );
    discover_candidates(store, &archive_params)
}

fn archive_profile_input(params: &Value) -> Result<Value> {
    if let Some(raw) = text_param(params, &["profileJson"]) {
        if !raw.trim().is_empty() {
            return Ok(serde_json::from_str(&raw)?);
        }
    }
    if let Some(path) = text_param(params, &["profileFile"]) {
        if !path.trim().is_empty() {
            return Ok(serde_json::from_str(&fs::read_to_string(expand_home(
                &path,
            ))?)?);
        }
    }
    let mut object = Map::<String, Value>::new();
    for key in [
        "profileId",
        "displayName",
        "archiveRoot",
        "baselineIndexPath",
    ] {
        if let Some(value) = text_param(params, &[key]) {
            if !value.trim().is_empty() {
                object.insert(key.to_string(), json!(value));
            }
        }
    }
    for key in [
        "canonicalNames",
        "aliasNames",
        "projectPaths",
        "expectedAgents",
        "expectedSources",
        "exclusionRules",
        "collectionPathSegments",
    ] {
        if let Some(value) = text_param(params, &[key]) {
            object.insert(key.to_string(), json!(split_path_list(&value)));
        }
    }
    Ok(Value::Object(object))
}

fn parse_archive_profile(value: &Value) -> Result<ArchiveProfile> {
    let display_name = text_value(value, "displayName")
        .or_else(|| text_value(value, "name"))
        .or_else(|| text_value(value, "profileId"))
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("archive profile requires displayName or profileId"))?;
    let profile_id = text_value(value, "profileId")
        .or_else(|| topic_key(&display_name))
        .map(|value| sanitize_id(&value))
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("archive profile id is empty"))?;
    let collection_path_segments = collection_path_segments_value(value, &profile_id);
    let expected_agents = string_list_value(value, "expectedAgents")
        .into_iter()
        .map(|agent| normalize_agent_alias(&agent))
        .collect::<Vec<_>>();
    Ok(ArchiveProfile {
        profile_id,
        display_name,
        collection_path_segments,
        archive_root: text_value(value, "archiveRoot").map(|path| expand_home(&path)),
        canonical_names: string_list_value(value, "canonicalNames"),
        alias_names: string_list_value(value, "aliasNames"),
        project_paths: string_list_value(value, "projectPaths"),
        expected_agents,
        expected_sources: string_list_value(value, "expectedSources"),
        exclusion_rules: string_list_value(value, "exclusionRules"),
        baseline_index_path: text_value(value, "baselineIndexPath").map(|path| expand_home(&path)),
        raw: value.clone(),
    })
}

fn collection_path_segments_value(value: &Value, fallback_profile_id: &str) -> Vec<String> {
    let mut segments = Vec::<String>::new();
    let mut seen = BTreeSet::<String>::new();
    for raw in string_list_value(value, "collectionPathSegments") {
        let segment = topic_key(&raw).unwrap_or_else(|| sanitize_id(&raw));
        if !segment.is_empty() && seen.insert(segment.clone()) {
            segments.push(segment);
        }
    }
    if segments.is_empty() {
        segments.push(fallback_profile_id.to_string());
    }
    segments
}

fn archive_profile_value(profile: &ArchiveProfile) -> Value {
    let mut object = profile.raw.as_object().cloned().unwrap_or_default();
    object.insert(
        "schemaVersion".to_string(),
        json!(COLLECTION_SCHEMA_VERSION),
    );
    object.insert("profileId".to_string(), json!(profile.profile_id));
    object.insert("displayName".to_string(), json!(profile.display_name));
    object.insert(
        "collectionPathSegments".to_string(),
        json!(profile.collection_path_segments),
    );
    object.insert(
        "archiveRoot".to_string(),
        profile
            .archive_root
            .as_ref()
            .map(|path| json!(display_path(path)))
            .unwrap_or_else(|| json!(null)),
    );
    object.insert("canonicalNames".to_string(), json!(profile.canonical_names));
    object.insert("aliasNames".to_string(), json!(profile.alias_names));
    object.insert("projectPaths".to_string(), json!(profile.project_paths));
    object.insert("expectedAgents".to_string(), json!(profile.expected_agents));
    object.insert(
        "expectedSources".to_string(),
        json!(profile.expected_sources),
    );
    object.insert("exclusionRules".to_string(), json!(profile.exclusion_rules));
    object.insert(
        "baselineIndexPath".to_string(),
        profile
            .baseline_index_path
            .as_ref()
            .map(|path| json!(display_path(path)))
            .unwrap_or_else(|| json!(null)),
    );
    Value::Object(object)
}

fn load_archive_profile(store: &ClientStateStore, params: &Value) -> Result<ArchiveProfile> {
    let profile_id = text_param(params, &["profile", "profileId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("archive profile command requires --profile"))?;
    let document = store.read_collection(PROFILES_COLLECTION)?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let wanted = sanitize_id(&profile_id);
    let value = items
        .iter()
        .find(|item| {
            item.get("profileId")
                .and_then(Value::as_str)
                .map(|id| id == wanted || id == profile_id)
                .unwrap_or(false)
        })
        .cloned()
        .ok_or_else(|| anyhow!("unknown conversation archive profile: {}", profile_id))?;
    parse_archive_profile(&value)
}

fn archive_root_for_profile(
    store: &ClientStateStore,
    params: &Value,
    profile: &ArchiveProfile,
) -> Result<PathBuf> {
    if let Some(root) = text_param(params, &["archiveRoot", "snapshotRoot"]) {
        if !root.trim().is_empty() {
            return Ok(expand_home(&root));
        }
    }
    if let Some(root) = &profile.archive_root {
        return Ok(root.clone());
    }
    Ok(snapshot_root(store, params)?.path)
}

fn collection_dir_for_profile(root: &Path, profile: &ArchiveProfile) -> PathBuf {
    collection_dir_for_profile_layout(root, profile, ArchiveCollectionLayout::CollectionsSubdir)
}

fn collection_dir_for_profile_layout(
    root: &Path,
    profile: &ArchiveProfile,
    layout: ArchiveCollectionLayout,
) -> PathBuf {
    let mut dir = root.join("collections");
    if layout == ArchiveCollectionLayout::DirectKeywordFolders {
        dir = root.to_path_buf();
    }
    for segment in &profile.collection_path_segments {
        dir = dir.join(segment);
    }
    dir
}

fn select_profile_archive_candidates(
    store: &ClientStateStore,
    params: &Value,
    profile: &ArchiveProfile,
    discovery: &DiscoveryResult,
) -> Result<(
    Vec<SelectedCandidate>,
    BTreeMap<String, ProfileMatch>,
    Value,
)> {
    let mut curation = curation_state(store, params)?;
    if let Some((session_id, result)) = curation_session_submitted_result(store, params)? {
        curation = json!({
            "enabled": true,
            "status": "session_result_submitted",
            "mode": "curation-session",
            "curationSessionId": session_id
        });
        let selected = selected_from_structured_result(&discovery.candidates, &result)?;
        let matches = curated_profile_matches(&selected);
        return Ok((selected, matches, curation));
    }
    if let Some(result) = curation_result(params)? {
        let selected = selected_from_structured_result(&discovery.candidates, &result)?;
        let matches = curated_profile_matches(&selected);
        return Ok((selected, matches, curation));
    }
    if curation.get("status").and_then(Value::as_str) == Some("available") {
        let invocation = invoke_preferred_curator(
            store,
            params,
            &profile.display_name,
            &profile.profile_id,
            discovery,
            &curation,
        )?;
        curation = invocation.curation;
        if let Some(result) = invocation.structured_result {
            let selected = selected_from_structured_result(&discovery.candidates, &result)?;
            let matches = curated_profile_matches(&selected);
            return Ok((selected, matches, curation));
        }
    }

    let mut selected = Vec::<SelectedCandidate>::new();
    let mut matches = BTreeMap::<String, ProfileMatch>::new();
    for candidate in &discovery.candidates {
        let Some(id) = candidate_id(candidate) else {
            continue;
        };
        let Some(profile_match) = profile_match(candidate, profile) else {
            continue;
        };
        if !candidate_has_real_conversation(candidate) {
            continue;
        }
        selected.push(SelectedCandidate {
            session: candidate.clone(),
            selection_mode: "deterministic".to_string(),
            reason: profile_match.reason.clone(),
            labels: vec![format!("confidence:{}", profile_match.confidence)],
            group: profile.profile_id.clone(),
            summary: String::new(),
        });
        matches.insert(id, profile_match);
    }
    if curation.get("status").and_then(Value::as_str).unwrap_or("") != "available" {
        curation = json!({
            "enabled": param_bool(params, "curation").unwrap_or(true),
            "status": "archive_profile_deterministic",
            "mode": "conversation-archive"
        });
    }
    Ok((selected, matches, curation))
}

fn curated_profile_matches(selected: &[SelectedCandidate]) -> BTreeMap<String, ProfileMatch> {
    let mut matches = BTreeMap::<String, ProfileMatch>::new();
    for item in selected {
        if let Some(id) = candidate_id(&item.session) {
            matches.insert(
                id,
                ProfileMatch {
                    matched_terms: vec!["curated".to_string()],
                    confidence: "medium".to_string(),
                    reason: item.reason.clone(),
                },
            );
        }
    }
    matches
}

fn profile_match(candidate: &Value, profile: &ArchiveProfile) -> Option<ProfileMatch> {
    let candidate_text = candidate_search_text(candidate);
    let normalized = normalize_match_text(&candidate_text);
    let candidate_path_text = candidate_path_text(candidate);
    let normalized_path = normalize_match_text(&candidate_path_text);
    let mut matched_terms = Vec::<String>::new();
    let mut matched_identity_keys = BTreeSet::<String>::new();
    let mut path_match = false;
    for term in &profile.project_paths {
        if term.trim().is_empty() {
            continue;
        }
        let normalized_term = normalize_match_text(term);
        if candidate_text.contains(term)
            || candidate_path_text.contains(term)
            || normalized_contains_identity_term(&normalized, &normalized_term)
            || normalized_contains_identity_term(&normalized_path, &normalized_term)
        {
            matched_terms.push(term.clone());
            let identity_key = compact_identity_key(term);
            if !identity_key.is_empty() {
                matched_identity_keys.insert(identity_key);
            }
            path_match = true;
        }
    }
    for term in profile
        .canonical_names
        .iter()
        .chain(profile.alias_names.iter())
    {
        if term.trim().is_empty() {
            continue;
        }
        let normalized_term = normalize_match_text(term);
        if !normalized_term.is_empty()
            && normalized_contains_identity_term(&normalized, &normalized_term)
        {
            matched_terms.push(term.clone());
            let identity_key = compact_identity_key(term);
            if !identity_key.is_empty() {
                matched_identity_keys.insert(identity_key);
            }
        }
    }
    matched_terms.sort();
    matched_terms.dedup();
    if matched_terms.is_empty() {
        return None;
    }
    let confidence = if path_match || matched_identity_keys.len() >= 2 {
        "high"
    } else if profile
        .alias_names
        .iter()
        .any(|term| matched_terms.iter().any(|matched| matched == term))
    {
        "medium"
    } else {
        "low"
    };
    Some(ProfileMatch {
        reason: format!("profile identity matched: {}", matched_terms.join(", ")),
        matched_terms,
        confidence: confidence.to_string(),
    })
}

fn candidate_has_real_conversation(candidate: &Value) -> bool {
    if candidate
        .get("archiveDiscoveryHasConversation")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return true;
    }
    candidate
        .get("messages")
        .and_then(Value::as_array)
        .map(|messages| messages.iter().any(message_has_real_conversation_content))
        .unwrap_or(false)
}

fn message_has_real_conversation_content(message: &Value) -> bool {
    let role = text_value(message, "role")
        .unwrap_or_default()
        .to_ascii_lowercase();
    let Some(text) = archive_message_text(message) else {
        return false;
    };
    if metadata_like_archive_text(&text) {
        return false;
    }
    if matches!(
        role.as_str(),
        "user" | "human" | "assistant" | "agent" | "model"
    ) {
        return true;
    }
    if matches!(role.as_str(), "transcript" | "record" | "") {
        return looks_like_archive_text_conversation(&text)
            || looks_like_archive_database_record(&text);
    }
    false
}

fn archive_message_text(message: &Value) -> Option<String> {
    for key in ["text", "content", "message"] {
        if let Some(text) = message.get(key).and_then(Value::as_str) {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn metadata_like_archive_text(text: &str) -> bool {
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

fn looks_like_archive_text_conversation(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    let structured_text = looks_like_structured_archive_text(raw);
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

fn looks_like_structured_archive_text(raw: &str) -> bool {
    let trimmed = raw.trim_start();
    trimmed.starts_with('{') || trimmed.starts_with('[')
}

fn looks_like_archive_database_record(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("message:")
        || lower.contains("messages:")
        || lower.contains("conversation:")
        || lower.contains("conversations:")
        || lower.contains("chat:")
        || lower.contains("chats:")
}

fn candidate_search_text(candidate: &Value) -> String {
    let mut parts = Vec::<String>::new();
    for key in ["title", "nativeSessionId"] {
        if let Some(text) = candidate.get(key).and_then(Value::as_str) {
            parts.push(text.to_string());
        }
    }
    if let Some(items) = candidate
        .get("archiveDiscoveryMatchedTerms")
        .and_then(Value::as_array)
    {
        for item in items {
            if let Some(text) = item.as_str() {
                parts.push(text.to_string());
            }
        }
    }
    if let Some(messages) = candidate.get("messages").and_then(Value::as_array) {
        for message in messages {
            if !message_is_matchable_conversation_text(message) {
                continue;
            }
            if let Some(text) = message.get("text").and_then(Value::as_str) {
                parts.push(text.to_string());
            }
        }
    }
    parts.join("\n")
}

fn message_is_matchable_conversation_text(message: &Value) -> bool {
    let role = text_value(message, "role")
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        role.as_str(),
        "user" | "human" | "assistant" | "agent" | "model"
    ) || (matches!(role.as_str(), "transcript" | "")
        && message
            .get("text")
            .and_then(Value::as_str)
            .map(looks_like_archive_text_conversation)
            .unwrap_or(false))
        || (role == "record"
            && message
                .get("text")
                .and_then(Value::as_str)
                .map(looks_like_archive_database_record)
                .unwrap_or(false))
}

fn candidate_path_text(candidate: &Value) -> String {
    let mut parts = Vec::<String>::new();
    for key in ["sourcePath", "workingDirectory", "cwd", "projectPath"] {
        if let Some(text) = candidate.get(key).and_then(Value::as_str) {
            parts.push(text.to_string());
        }
    }
    if let Some(messages) = candidate.get("messages").and_then(Value::as_array) {
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

fn extend_unique_candidates(
    candidates: &mut Vec<Value>,
    seen: &mut BTreeSet<String>,
    sessions: Vec<Value>,
) {
    for session in sessions {
        let id = candidate_id(&session).unwrap_or_else(|| {
            hash_text(
                &serde_json::to_string(&session)
                    .unwrap_or_else(|_| "unknown-native-session".to_string()),
            )
        });
        if seen.insert(id) {
            candidates.push(session);
        }
    }
}

fn manual_history_roots(
    store: &ClientStateStore,
    params: &Value,
    agent: &str,
) -> Result<Vec<PathBuf>> {
    if params.get("targetScan").is_some() {
        return Ok(target_scan_history_roots(params, agent));
    }
    let document = store.read_collection(TARGETS_COLLECTION)?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut roots = Vec::<PathBuf>::new();
    let mut seen = BTreeSet::<String>::new();
    let wanted = normalize_agent_alias(agent);
    for item in items {
        let item_target = item
            .get("target")
            .and_then(Value::as_str)
            .map(normalize_agent_alias)
            .unwrap_or_default();
        if item_target != wanted {
            continue;
        }
        for root in history_roots_from_value(item.get("historyRoots"))
            .into_iter()
            .chain(history_roots_from_value(item.get("historyRoot")))
        {
            let key = display_path(&root);
            if seen.insert(key) {
                roots.push(root);
            }
        }
    }
    Ok(roots)
}

fn target_scan_history_roots(params: &Value, agent: &str) -> Vec<PathBuf> {
    let wanted = normalize_agent_alias(agent);
    let mut roots = Vec::<PathBuf>::new();
    let mut seen = BTreeSet::<String>::new();
    for candidate in params
        .get("targetScan")
        .and_then(|scan| scan.get("candidates"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let candidate_agent = candidate
            .get("target")
            .and_then(Value::as_str)
            .map(normalize_agent_alias)
            .unwrap_or_default();
        if candidate_agent != wanted {
            continue;
        }
        for root in history_roots_from_value(candidate.get("historyRoots"))
            .into_iter()
            .chain(history_roots_from_value(candidate.get("historyRoot")))
        {
            let key = display_path(&root);
            if seen.insert(key) {
                roots.push(root);
            }
        }
    }
    roots
}

fn remote_history_targets(params: &Value, agent: &str) -> Vec<RemoteHistoryTarget> {
    let wanted = normalize_agent_alias(agent);
    params
        .get("targetScan")
        .and_then(|scan| scan.get("candidates"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|candidate| remote_history_target_from_candidate(candidate, &wanted))
        .collect()
}

fn remote_history_target_from_candidate(
    candidate: &Value,
    wanted: &str,
) -> Option<RemoteHistoryTarget> {
    let agent_id = candidate
        .get("target")
        .and_then(Value::as_str)
        .map(normalize_agent_alias)?;
    if agent_id != wanted {
        return None;
    }
    let location = candidate
        .get("location")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && *value != "local")?
        .to_string();
    let relative_paths = remote_history_relative_paths_for_candidate(candidate, &agent_id);
    if relative_paths.is_empty() {
        return None;
    }
    let overrides = candidate
        .get("optionOverrides")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let context_id = remote_override_text(
        &overrides,
        &["remote-id", "orb-vm", "openclaw-vm", "hermes-vm"],
    )
    .unwrap_or_else(|| "default".to_string());
    let context_name = remote_override_text(
        &overrides,
        &["remote-name", "orb-vm", "openclaw-vm", "hermes-vm"],
    )
    .unwrap_or_else(|| context_id.clone());
    let user = remote_override_text(&overrides, &["orb-user", "openclaw-user", "hermes-user"])
        .unwrap_or_default();
    let runtime_bin = remote_override_text(
        &overrides,
        &[
            "remote-bin",
            "orb-bin",
            "docker-bin",
            "podman-bin",
            "nerdctl-bin",
            "wsl-bin",
            "lima-bin",
            "colima-bin",
            "multipass-bin",
            "lxc-bin",
            "incus-bin",
            "vagrant-bin",
            "parallels-bin",
        ],
    )
    .unwrap_or_else(|| default_remote_runtime_bin(&location).to_string());
    Some(RemoteHistoryTarget {
        candidate_id: candidate
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        agent_id,
        label: candidate
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        location,
        context_id,
        context_name,
        user,
        runtime_bin,
        relative_paths,
    })
}

fn mirror_remote_history(
    store: &ClientStateStore,
    target: &RemoteHistoryTarget,
) -> Result<PathBuf> {
    let relative_paths = target
        .relative_paths
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    if relative_paths.is_empty() {
        return Err(anyhow!(
            "remote history mirroring has no registered paths for {}",
            target.agent_id
        ));
    }
    let mirror_id = hash_text(&format!(
        "{}:{}:{}:{}:{}",
        target.agent_id,
        target.location,
        target.context_id,
        target.user,
        timestamp_stamp()
    ));
    let mirror_home = store
        .root()
        .join("remote-history-mirrors")
        .join(&mirror_id[..24]);
    ensure_private_dir(&mirror_home)?;
    let tar_output = remote_history_tar(target, &relative_paths)?;
    if tar_output.is_empty() {
        return Err(anyhow!("remote history mirror returned an empty archive"));
    }
    extract_tar_gz(&tar_output, &mirror_home)?;
    harden_private_tree(&mirror_home)?;
    Ok(mirror_home)
}

fn remote_history_tar(target: &RemoteHistoryTarget, relative_paths: &[&str]) -> Result<Vec<u8>> {
    let script = remote_history_tar_script(relative_paths);
    let output = match target.location.as_str() {
        "orb" => {
            if target.context_id.is_empty() || target.user.is_empty() {
                return Err(anyhow!("Orb remote history scan requires VM and user"));
            }
            Command::new(&target.runtime_bin)
                .args([
                    "-m",
                    target.context_id.as_str(),
                    "-u",
                    target.user.as_str(),
                    "bash",
                    "-lc",
                    script.as_str(),
                ])
                .output()
        }
        "docker" | "podman" | "nerdctl" => Command::new(&target.runtime_bin)
            .args([
                "exec",
                target.context_id.as_str(),
                "sh",
                "-lc",
                script.as_str(),
            ])
            .output(),
        "wsl" => Command::new(&target.runtime_bin)
            .args([
                "-d",
                target.context_id.as_str(),
                "--",
                "bash",
                "-lc",
                script.as_str(),
            ])
            .output(),
        "lima" => Command::new(&target.runtime_bin)
            .args([
                "shell",
                target.context_id.as_str(),
                "bash",
                "-lc",
                script.as_str(),
            ])
            .output(),
        "colima" => Command::new(&target.runtime_bin)
            .args([
                "ssh",
                target.context_id.as_str(),
                "--",
                "bash",
                "-lc",
                script.as_str(),
            ])
            .output(),
        "multipass" | "lxc" | "incus" => Command::new(&target.runtime_bin)
            .args([
                "exec",
                target.context_id.as_str(),
                "--",
                "bash",
                "-lc",
                script.as_str(),
            ])
            .output(),
        "vagrant" => Command::new(&target.runtime_bin)
            .args([
                "ssh",
                target.context_id.as_str(),
                "-c",
                format!("bash -lc {}", shell_quote(&script)).as_str(),
            ])
            .output(),
        "parallels" => Command::new(&target.runtime_bin)
            .args([
                "exec",
                target.context_id.as_str(),
                "bash",
                "-lc",
                script.as_str(),
            ])
            .output(),
        other => return Err(anyhow!("unsupported remote history location: {}", other)),
    }
    .map_err(|error| {
        anyhow!(
            "remote history scan command failed to start for {}:{}: {}",
            target.location,
            target.context_id,
            error
        )
    })?;
    if !output.status.success() {
        if output.status.code() == Some(3) {
            return Err(anyhow!(
                "no remote history paths found for {}:{}",
                target.location,
                target.context_id
            ));
        }
        return Err(anyhow!(
            "remote history scan failed for {}:{}: {}",
            target.location,
            target.context_id,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(output.stdout)
}

fn remote_history_tar_script(relative_paths: &[&str]) -> String {
    let checks = relative_paths
        .iter()
        .map(|path| {
            format!(
                "if [ -e {quoted} ]; then found=1; printf '%s\\0' {quoted}; fi",
                quoted = shell_quote(path)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "set -e\ncd \"$HOME\"\nfound=0\n{{\n{}\n}} > /tmp/lico-remote-history-paths.$$ \nif [ \"$found\" = \"0\" ]; then rm -f /tmp/lico-remote-history-paths.$$; exit 3; fi\ntar --null -czf - -T /tmp/lico-remote-history-paths.$$ 2>/dev/null\nrm -f /tmp/lico-remote-history-paths.$$",
        checks
    )
}

fn extract_tar_gz(bytes: &[u8], destination: &Path) -> Result<()> {
    // Use the safe Rust-native extractor that enforces path traversal
    // rejection, entry type allowlisting, and byte/entry/depth limits.
    safe_archive::extract_tar_gz_safe(bytes, destination, None, None, None)
}

fn remote_history_relative_paths(agent: &str) -> Vec<&'static str> {
    match agent {
        "antigravity" => vec![
            ".config/Antigravity IDE",
            ".gemini/antigravity",
            ".gemini/antigravity-ide",
        ],
        "code" => vec![
            ".config/Code/User/workspaceStorage",
            ".config/Code/User/globalStorage",
        ],
        "codex" => vec![
            ".codex/history.jsonl",
            ".codex/session_index.jsonl",
            ".codex/sessions",
            ".codex/archived_sessions",
            ".codex/memories",
        ],
        "claude-code" => vec![".claude/projects", ".claude.json"],
        "copilot" => vec![
            ".config/Code/User/workspaceStorage",
            ".config/Code/User/globalStorage",
        ],
        "cursor" => vec![
            ".config/Cursor/User/workspaceStorage",
            ".config/Cursor/User/globalStorage",
        ],
        "hermes" => vec![".hermes", ".config/hermes"],
        "kilo-code" => vec![
            ".local/share/kilo/kilo.db",
            ".local/share/kilo/storage/session_diff",
            ".local/share/kilo/storage/session_share",
            ".local/share/kilo/log",
            ".config/kilo",
        ],
        "kimi" => vec![".config/Kimi", ".local/share/Kimi"],
        "kimi-code" => vec![".kimi-code/session_index.jsonl", ".kimi-code/sessions"],
        "openclaw" => vec![".openclaw", ".config/openclaw"],
        "opencode" => vec![".config/opencode", ".local/share/opencode"],
        "pi" => vec![".pi/agent/sessions", ".pi/agent"],
        _ => Vec::new(),
    }
}

fn remote_history_relative_paths_for_candidate(candidate: &Value, agent: &str) -> Vec<String> {
    let mut paths = remote_history_relative_paths_from_value(candidate.get("remoteHistoryRoots"));
    if paths.is_empty() {
        paths = remote_history_relative_paths(agent)
            .into_iter()
            .map(str::to_string)
            .collect();
    }
    paths
}

fn remote_history_relative_paths_from_value(value: Option<&Value>) -> Vec<String> {
    let mut paths = Vec::<String>::new();
    let mut seen = BTreeSet::<String>::new();
    let roots = match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .flat_map(split_path_list)
            .collect::<Vec<_>>(),
        Some(Value::String(text)) => split_path_list(text),
        _ => Vec::new(),
    };
    for root in roots {
        if let Some(relative_path) = remote_history_relative_path_from_root(&root) {
            if seen.insert(relative_path.clone()) {
                paths.push(relative_path);
            }
        }
    }
    paths
}

fn remote_history_relative_path_from_root(root: &str) -> Option<String> {
    let trimmed = root.trim();
    let marker = "/$HOME/";
    let relative = trimmed
        .split_once(marker)
        .map(|(_, suffix)| suffix.trim_start_matches('/'))?;
    if relative.is_empty() {
        None
    } else {
        Some(relative.to_string())
    }
}

fn default_remote_runtime_bin(location: &str) -> &str {
    match location {
        "orb" => "orb",
        "docker" => "docker",
        "podman" => "podman",
        "nerdctl" => "nerdctl",
        "wsl" => "wsl",
        "lima" => "limactl",
        "colima" => "colima",
        "multipass" => "multipass",
        "lxc" => "lxc",
        "incus" => "incus",
        "vagrant" => "vagrant",
        "parallels" => "prlctl",
        _ => location,
    }
}

fn remote_override_text(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn selected_from_structured_result(
    candidates: &[Value],
    result: &Value,
) -> Result<Vec<SelectedCandidate>> {
    let mut candidate_map = BTreeMap::<String, Value>::new();
    for candidate in candidates {
        if let Some(id) = candidate_id(candidate) {
            candidate_map.insert(id, candidate.clone());
        }
    }
    let selections = result
        .get("selectedCandidateIds")
        .or_else(|| result.get("selected"))
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("structured curation result requires selectedCandidateIds"))?;
    let labels_by_id = object_map(result.get("labelsByCandidateId"));
    let groups_by_id = object_map(result.get("groupsByCandidateId"));
    let summaries_by_id = object_map(result.get("summariesByCandidateId"));
    let reasons_by_id = object_map(result.get("reasonsByCandidateId"));
    let mut selected = Vec::<SelectedCandidate>::new();
    for value in selections {
        let Some(id) = value.as_str().map(str::to_string) else {
            continue;
        };
        let Some(candidate) = candidate_map.get(&id) else {
            return Err(anyhow!("curation selected unknown candidate id: {}", id));
        };
        selected.push(SelectedCandidate {
            session: candidate.clone(),
            selection_mode: "curated".to_string(),
            reason: reasons_by_id
                .get(&id)
                .and_then(Value::as_str)
                .unwrap_or("structured curator selected this candidate")
                .to_string(),
            labels: labels_by_id
                .get(&id)
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default(),
            group: groups_by_id
                .get(&id)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            summary: summaries_by_id
                .get(&id)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        });
    }
    Ok(selected)
}

fn materialize_snapshot(
    collection_dir: &Path,
    topic: &str,
    topic_key: &str,
    selected: &SelectedCandidate,
    refreshed_at: &str,
) -> Result<Value> {
    let session = &selected.session;
    let adapter_id = text_value(session, "adapterId")
        .or_else(|| text_value(session, "agentId"))
        .unwrap_or_else(|| "unknown".to_string());
    let source_client = text_value(session, "sourceClient")
        .or_else(|| text_value(session, "sourceTool"))
        .unwrap_or_else(|| adapter_id.clone());
    let source_client_label = text_value(session, "sourceClientLabel").unwrap_or_default();
    let host_app = text_value(session, "hostApp").unwrap_or_default();
    let host_app_label = text_value(session, "hostAppLabel").unwrap_or_default();
    let source_label = text_value(session, "sourceLabel").unwrap_or_else(|| source_client.clone());
    let native_identity = native_identity(session);
    let snapshot_hash = hash_parts(&[&adapter_id, &native_identity]);
    let snapshot_id = format!("native-conversation-{}", &snapshot_hash[..24]);
    let conversation_dir = collection_dir.join("conversations").join(&snapshot_hash);
    fs::create_dir_all(&conversation_dir)?;

    let raw = export_raw_content(session)?;
    let raw_path = conversation_dir.join(&raw.file_name);
    atomic_write_text(&raw_path, &raw.content)?;
    let raw_hash = hash_text(&raw.content);
    let adapter_label = text_value(session, "adapterLabel").unwrap_or_else(|| adapter_id.clone());
    let source_kind = text_value(session, "sourceKind").unwrap_or_else(|| "unknown".to_string());
    let source_path_value = text_value(session, "sourcePath").unwrap_or_default();
    let semantic = session.get("semantic").cloned().unwrap_or_else(|| {
        crate::domain::conversation_semantic::build_semantic_conversation(
            session
                .get("messages")
                .and_then(Value::as_array)
                .map(|messages| messages.as_slice())
                .unwrap_or(&[]),
            crate::domain::conversation_semantic::SemanticAuditInput {
                adapter_id: &adapter_id,
                adapter_label: &adapter_label,
                host_app: &host_app,
                host_app_label: &host_app_label,
                source_client: &source_client,
                source_kind: &source_kind,
                native_session_id: &native_identity,
                path_ref: &source_path_value,
                content_hash: &raw_hash,
                byte_length: raw.content.len() as u64,
                parse_warnings: &[],
                redaction_status: "applied",
                validation_status: "unchecked",
                created_at: refreshed_at,
                updated_at: refreshed_at,
            },
        )
        .unwrap_or_else(|_| json!({}))
    });
    let mut semantic_document = semantic;
    if let Some(object) = semantic_document.as_object_mut() {
        let mut artifacts = object
            .get("artifacts")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        artifacts.push(json!({
            "id": format!("artifact-summary-{snapshot_hash}"),
            "layer": "artifacts",
            "kind": "summary",
            "label": "Archive summary",
            "ref": SUMMARY_MD
        }));
        artifacts.push(json!({
            "id": format!("artifact-index-{snapshot_hash}"),
            "layer": "artifacts",
            "kind": "index",
            "label": "Conversation index",
            "ref": CONVERSATION_INDEX_MD
        }));
        artifacts.push(json!({
            "id": format!("artifact-validation-{snapshot_hash}"),
            "layer": "artifacts",
            "kind": "validation",
            "label": "Archive validation",
            "ref": VALIDATION_JSON
        }));
        artifacts.push(json!({
            "id": format!("artifact-raw-{snapshot_hash}"),
            "layer": "artifacts",
            "kind": "archive-path",
            "label": "Raw source export",
            "ref": raw.file_name,
            "contentHash": raw_hash
        }));
        object.insert("artifacts".to_string(), Value::Array(artifacts));
        if let Some(raw_block) = object.get_mut("raw").and_then(Value::as_object_mut) {
            raw_block.insert(
                "evidenceRefs".to_string(),
                json!([{
                    "kind": crate::domain::conversation_semantic::evidence_kind_from_source(
                        source_kind.as_str()
                    ),
                    "pathRef": raw.file_name,
                    "contentHash": raw_hash,
                    "byteLength": raw.content.len()
                }]),
            );
        }
        if let Some(audit) = object.get_mut("audit").and_then(Value::as_object_mut) {
            audit.insert("validationStatus".to_string(), json!("ok"));
            audit.insert(
                "sourceEvidence".to_string(),
                json!({
                    "kind": crate::domain::conversation_semantic::evidence_kind_from_source(
                        source_kind.as_str()
                    ),
                    "pathRef": raw.file_name,
                    "contentHash": raw_hash,
                    "byteLength": raw.content.len()
                }),
            );
        }
    }
    let _ =
        crate::domain::conversation_semantic::validate_semantic_conversation(&semantic_document);
    let (semantic_json_path, semantic_md_path, semantic_hash) =
        crate::domain::conversation_semantic::materialize_semantic_documents(
            &conversation_dir,
            &semantic_document,
        )?;
    let snapshot_path = conversation_dir.join(SNAPSHOT_JSON);
    let snapshot = json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "kind": "native-conversation-snapshot",
        "snapshotId": snapshot_id,
        "topic": topic,
        "topicKey": topic_key,
        "agentAdapterId": adapter_id,
        "sourceClient": source_client,
        "sourceClientLabel": source_client_label,
        "hostApp": host_app,
        "hostAppLabel": host_app_label,
        "sourceLabel": source_label,
        "nativeConversationIdentity": native_identity,
        "sourcePath": session.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "sourceKind": session.get("sourceKind").cloned().unwrap_or_else(|| json!("")),
        "title": session.get("title").cloned().unwrap_or_else(|| json!("Native agent history")),
        "messageCount": session.get("messageCount").cloned().unwrap_or_else(|| json!(0)),
        "selection": {
            "mode": selected.selection_mode,
            "reason": selected.reason,
            "labels": selected.labels,
            "group": selected.group,
            "summary": selected.summary
        },
        "semanticDocumentFile": SEMANTIC_JSON,
        "semanticDocumentPath": display_path(&semantic_json_path),
        "semanticMarkdownFile": SEMANTIC_MD,
        "semanticMarkdownPath": display_path(&semantic_md_path),
        "semanticContentHash": semantic_hash,
        "semantic": semantic_document,
        "rawContentFile": raw.file_name,
        "rawContentPath": display_path(&raw_path),
        "rawContentHash": raw_hash,
        "rawContentBytes": raw.content.len(),
        "rawExportKind": raw.export_kind,
        "diagnostics": raw.diagnostics,
        "createdAt": existing_created_at(&snapshot_path).unwrap_or_else(|| refreshed_at.to_string()),
        "refreshedAt": refreshed_at
    });
    atomic_write_json(&snapshot_path, &snapshot)?;
    Ok(json!({
        "snapshotId": snapshot.get("snapshotId").cloned().unwrap_or_else(|| json!("")),
        "agentAdapterId": snapshot.get("agentAdapterId").cloned().unwrap_or_else(|| json!("")),
        "sourceClient": snapshot.get("sourceClient").cloned().unwrap_or_else(|| json!("")),
        "sourceClientLabel": snapshot.get("sourceClientLabel").cloned().unwrap_or_else(|| json!("")),
        "hostApp": snapshot.get("hostApp").cloned().unwrap_or_else(|| json!("")),
        "hostAppLabel": snapshot.get("hostAppLabel").cloned().unwrap_or_else(|| json!("")),
        "sourceLabel": snapshot.get("sourceLabel").cloned().unwrap_or_else(|| json!("")),
        "nativeConversationIdentity": snapshot.get("nativeConversationIdentity").cloned().unwrap_or_else(|| json!("")),
        "title": snapshot.get("title").cloned().unwrap_or_else(|| json!("")),
        "sourcePath": snapshot.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "messageCount": snapshot.get("messageCount").cloned().unwrap_or_else(|| json!(0)),
        "snapshotPath": display_path(&snapshot_path),
        "semanticDocumentPath": display_path(&semantic_json_path),
        "semanticMarkdownPath": display_path(&semantic_md_path),
        "semanticContentHash": snapshot.get("semanticContentHash").cloned().unwrap_or_else(|| json!("")),
        "rawContentPath": display_path(&raw_path),
        "rawContentHash": snapshot.get("rawContentHash").cloned().unwrap_or_else(|| json!("")),
        "rawContentBytes": snapshot.get("rawContentBytes").cloned().unwrap_or_else(|| json!(0)),
        "rawExportKind": snapshot.get("rawExportKind").cloned().unwrap_or_else(|| json!("")),
        "selection": snapshot.get("selection").cloned().unwrap_or_else(|| json!({})),
        "createdAt": snapshot.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "refreshedAt": refreshed_at
    }))
}

fn export_raw_content(session: &Value) -> Result<RawExport> {
    let source_path = text_value(session, "sourcePath")
        .map(PathBuf::from)
        .unwrap_or_default();
    let native_id = text_value(session, "nativeSessionId").unwrap_or_else(|| "file".to_string());
    let extension = source_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let export = if source_path.exists() {
        match extension.as_str() {
            "jsonl" | "ndjson" => export_jsonl_source(&source_path, &native_id),
            "json" => export_json_source(&source_path, &native_id),
            "sqlite" | "sqlite3" | "db" | "vscdb" => export_sqlite_source(&source_path, session),
            "md" | "markdown" => export_whole_file(&source_path, "source.md", "source-file"),
            "txt" | "log" => export_whole_file(&source_path, "source.txt", "source-file"),
            _ => export_whole_file(&source_path, "source.txt", "source-file"),
        }
    } else {
        Ok(RawExport {
            file_name: "source.json".to_string(),
            content: format!("{}\n", serde_json::to_string_pretty(session)?),
            export_kind: "parsed-session-source-missing".to_string(),
            diagnostics: vec![json!({
                "stage": "raw_export",
                "status": "source_missing",
                "sourcePath": display_path(&source_path)
            })],
        })
    };
    export.map(|export| parsed_session_fallback_for_empty_raw(export, session))
}

fn export_jsonl_source(path: &Path, native_id: &str) -> Result<RawExport> {
    let raw = fs::read_to_string(path)?;
    let mut lines = filter_codex_rollout_jsonl_source(&raw, native_id);
    let export_kind = if lines.is_empty() {
        "jsonl-native-session-records".to_string()
    } else {
        "codex-rollout-jsonl-native-session-records".to_string()
    };
    if lines.is_empty() {
        for line in raw.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let matches = serde_json::from_str::<Value>(trimmed)
                .ok()
                .and_then(|value| extract_native_session_id(&value))
                .map(|id| id == native_id)
                .unwrap_or(native_id == "file");
            if matches {
                lines.push(line.to_string());
            }
        }
    }
    let diagnostics = if lines.is_empty() {
        vec![json!({
            "stage": "raw_export",
            "status": "filter_empty_used_full_source",
            "sourcePath": display_path(path)
        })]
    } else {
        Vec::new()
    };
    Ok(RawExport {
        file_name: "source.jsonl".to_string(),
        content: if lines.is_empty() {
            raw
        } else {
            format!("{}\n", lines.join("\n"))
        },
        export_kind,
        diagnostics,
    })
}

fn filter_codex_rollout_jsonl_source(raw: &str, native_id: &str) -> Vec<String> {
    if native_id.trim().is_empty() || native_id == "file" {
        return Vec::new();
    }
    let mut lines = Vec::<String>::new();
    let mut current_session_id: Option<String> = None;
    let mut saw_rollout = false;
    for line in raw.lines() {
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
        let Some(payload) = value.get("payload") else {
            continue;
        };
        if !matches!(
            event_type,
            "session_meta" | "turn_context" | "response_item" | "event_msg"
        ) {
            continue;
        }
        saw_rollout = true;
        if event_type == "session_meta" {
            current_session_id = payload
                .get("id")
                .and_then(Value::as_str)
                .map(str::to_string);
        }
        if current_session_id.as_deref() == Some(native_id)
            && codex_rollout_raw_line_is_conversation(&value)
        {
            lines.push(line.to_string());
        }
    }
    if saw_rollout { lines } else { Vec::new() }
}

fn codex_rollout_raw_line_is_conversation(value: &Value) -> bool {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return false;
    }
    let Some(payload) = value.get("payload") else {
        return false;
    };
    if payload.get("type").and_then(Value::as_str) != Some("message") {
        return false;
    }
    if !matches!(
        payload
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "user" | "assistant" | "agent" | "model"
    ) {
        return false;
    }
    payload
        .get("content")
        .or_else(|| payload.get("text"))
        .and_then(archive_extract_text)
        .map(|text| !metadata_like_archive_text(&text))
        .unwrap_or(false)
}

fn archive_extract_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(items) => {
            let parts = items
                .iter()
                .filter_map(archive_extract_text)
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join("\n"))
            }
        }
        Value::Object(object) => {
            for key in ["text", "content", "message", "prompt", "response", "answer"] {
                if let Some(text) = object.get(key).and_then(archive_extract_text) {
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

fn export_json_source(path: &Path, native_id: &str) -> Result<RawExport> {
    let raw = fs::read_to_string(path)?;
    let value = serde_json::from_str::<Value>(&raw).ok();
    if let Some(filtered) = value
        .as_ref()
        .and_then(|value| filter_json_session(value, native_id))
    {
        return Ok(RawExport {
            file_name: "source.json".to_string(),
            content: format!("{}\n", serde_json::to_string_pretty(&filtered)?),
            export_kind: "json-native-session-records".to_string(),
            diagnostics: Vec::new(),
        });
    }
    Ok(RawExport {
        file_name: "source.json".to_string(),
        content: raw,
        export_kind: "json-source-file".to_string(),
        diagnostics: vec![json!({
            "stage": "raw_export",
            "status": "json_filter_unavailable_used_full_source",
            "sourcePath": display_path(path)
        })],
    })
}

fn export_whole_file(path: &Path, file_name: &str, export_kind: &str) -> Result<RawExport> {
    Ok(RawExport {
        file_name: file_name.to_string(),
        content: fs::read_to_string(path)?,
        export_kind: export_kind.to_string(),
        diagnostics: Vec::new(),
    })
}

fn parsed_session_fallback_for_empty_raw(mut export: RawExport, session: &Value) -> RawExport {
    if raw_export_has_real_conversation(&export.content)
        || !candidate_has_real_conversation(session)
    {
        return export;
    }
    export.diagnostics.push(json!({
        "stage": "raw_export",
        "status": "parsed_session_used_because_raw_export_lacked_conversation_content",
        "previousExportKind": export.export_kind
    }));
    RawExport {
        file_name: "source.json".to_string(),
        content: format!(
            "{}\n",
            serde_json::to_string_pretty(session).unwrap_or_else(|_| "{}".to_string())
        ),
        export_kind: "parsed-session-raw-fallback".to_string(),
        diagnostics: export.diagnostics,
    }
}

fn raw_export_has_real_conversation(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    let structured_text = looks_like_structured_archive_text(raw);
    (structured_text
        && (lower.contains("\"role\":\"user\"")
            || lower.contains("\"role\": \"user\"")
            || lower.contains("\"role\":\"assistant\"")
            || lower.contains("\"role\": \"assistant\"")
            || lower.contains("\"type\":\"user\"")
            || lower.contains("\"type\": \"user\"")))
        || (lower.contains("\"rows\"") && looks_like_archive_database_record(raw))
        || lower.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with("user:")
                || line.starts_with("human:")
                || line.starts_with("assistant:")
                || line.starts_with("agent:")
        })
}

fn export_sqlite_source(path: &Path, session: &Value) -> Result<RawExport> {
    let messages = session
        .get("messages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut rows = Vec::<Value>::new();
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_URI
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let mut seen = BTreeSet::<(String, String)>::new();
    for message in messages {
        let table = text_value(&message, "sourceTable").unwrap_or_default();
        let key = text_value(&message, "sourceKey").unwrap_or_default();
        let fields = message.get("sourceFields").cloned();
        let identity = if key.is_empty() {
            fields
                .as_ref()
                .map(|value| hash_text(&serde_json::to_string(value).unwrap_or_default()))
                .unwrap_or_default()
        } else {
            key.clone()
        };
        if table.is_empty() || identity.is_empty() || !seen.insert((table.clone(), identity)) {
            continue;
        }
        if !key.is_empty() {
            if let Some(row) = sqlite_row_by_key(&connection, &table, &key)? {
                rows.push(row);
            }
        } else if let Some(fields) = fields {
            rows.push(json!({
                "table": table,
                "key": null,
                "fields": fields
            }));
        }
    }
    if rows.is_empty() {
        return Ok(RawExport {
            file_name: "source.sqlite-export.json".to_string(),
            content: format!(
                "{}\n",
                serde_json::to_string_pretty(&json!({
                    "sourcePath": display_path(path),
                    "nativeConversationIdentity": native_identity(session),
                    "exportStatus": "parsed-session-only",
                    "session": session
                }))?
            ),
            export_kind: "sqlite-parsed-session-fallback".to_string(),
            diagnostics: vec![json!({
                "stage": "raw_export",
                "status": "sqlite_row_identity_unavailable",
                "sourcePath": display_path(path)
            })],
        });
    }
    Ok(RawExport {
        file_name: "source.sqlite-export.json".to_string(),
        content: format!(
            "{}\n",
            serde_json::to_string_pretty(&json!({
                "sourcePath": display_path(path),
                "nativeConversationIdentity": native_identity(session),
                "rows": rows
            }))?
        ),
        export_kind: "sqlite-native-session-records".to_string(),
        diagnostics: Vec::new(),
    })
}

fn sqlite_row_by_key(connection: &Connection, table: &str, key: &str) -> Result<Option<Value>> {
    let escaped_table = table.replace('"', "\"\"");
    let query = format!(
        "SELECT * FROM \"{}\" WHERE key = ?1 OR id = ?1 LIMIT 1",
        escaped_table
    );
    let mut statement = match connection.prepare(&query) {
        Ok(statement) => statement,
        Err(_) => return Ok(None),
    };
    let column_names = statement
        .column_names()
        .iter()
        .map(|name| name.to_string())
        .collect::<Vec<_>>();
    let mut rows = statement.query([key])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let mut fields = Map::<String, Value>::new();
    for (index, name) in column_names.iter().enumerate() {
        let text = row
            .get_ref(index)
            .map(sqlite_value_text)
            .unwrap_or_default();
        fields.insert(name.clone(), json!(text));
    }
    Ok(Some(json!({
        "table": table,
        "key": key,
        "fields": fields
    })))
}

fn build_collection(
    existing: &Value,
    topic: &str,
    topic_key: &str,
    root: &Path,
    status: &str,
    conversations: Vec<Value>,
    refreshed_at: &str,
    source_summaries: &[Value],
    diagnostics: &[Value],
    curation: &Value,
    selected_count: usize,
    candidate_count: usize,
) -> Value {
    json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "kind": "native-conversation-snapshot-collection",
        "topic": topic,
        "displayTitle": existing.get("displayTitle").and_then(Value::as_str).unwrap_or(topic),
        "topicKey": topic_key,
        "snapshotRoot": display_path(root),
        "state": status,
        "createdAt": existing.get("createdAt").and_then(Value::as_str).unwrap_or(refreshed_at),
        "refreshedAt": refreshed_at,
        "latestRefreshSummary": {
            "candidateCount": candidate_count,
            "selectedCount": selected_count,
            "sourceCount": source_summaries.len(),
            "curatorStatus": curation.get("status").cloned().unwrap_or_else(|| json!("fallback_deterministic"))
        },
        "curation": curation,
        "sources": source_summaries,
        "diagnostics": diagnostics,
        "conversations": conversations
    })
}

fn empty_collection(topic: &str, topic_key: &str, root: &Path) -> Value {
    let now = timestamp_rfc3339();
    json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "kind": "native-conversation-snapshot-collection",
        "topic": topic,
        "displayTitle": topic,
        "topicKey": topic_key,
        "snapshotRoot": display_path(root),
        "state": "empty",
        "createdAt": now,
        "refreshedAt": now,
        "latestRefreshSummary": {},
        "curation": {},
        "sources": [],
        "diagnostics": [],
        "conversations": []
    })
}

fn existing_conversations(collection: &Value) -> Vec<Value> {
    collection
        .get("conversations")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn upsert_conversation_record(conversations: &mut Vec<Value>, record: Value) {
    let snapshot_id = record
        .get("snapshotId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if let Some(existing) = conversations
        .iter_mut()
        .find(|item| item.get("snapshotId").and_then(Value::as_str) == Some(snapshot_id.as_str()))
    {
        *existing = record;
    } else {
        conversations.push(record);
    }
    conversations.sort_by(|left, right| {
        right
            .get("refreshedAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                left.get("refreshedAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });
}

fn collection_summary(collection: &Value, path: &Path) -> Value {
    json!({
        "schemaVersion": collection.get("schemaVersion").cloned().unwrap_or_else(|| json!(COLLECTION_SCHEMA_VERSION)),
        "topic": collection.get("topic").cloned().unwrap_or_else(|| json!("")),
        "displayTitle": collection.get("displayTitle").cloned().unwrap_or_else(|| json!("")),
        "topicKey": collection.get("topicKey").cloned().unwrap_or_else(|| json!("")),
        "state": collection.get("state").cloned().unwrap_or_else(|| json!("empty")),
        "createdAt": collection.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "refreshedAt": collection.get("refreshedAt").cloned().unwrap_or_else(|| json!("")),
        "conversationCount": collection.get("conversations").and_then(Value::as_array).map(Vec::len).unwrap_or(0),
        "collectionPath": display_path(path),
        "latestRefreshSummary": collection.get("latestRefreshSummary").cloned().unwrap_or_else(|| json!({}))
    })
}

fn archive_key_for_session(session: &Value) -> String {
    native_identity(session)
}

fn archive_status_for(previous: Option<&Value>, fingerprint: &str) -> String {
    match previous {
        None => "new".to_string(),
        Some(record)
            if record
                .get("content_fingerprint")
                .and_then(Value::as_str)
                .unwrap_or_default()
                == fingerprint =>
        {
            "unchanged".to_string()
        }
        Some(_) => "updated".to_string(),
    }
}

fn archive_index_record(
    archive_key: &str,
    session: &Value,
    record: &Value,
    profile_match: &ProfileMatch,
    archive_status: &str,
    refreshed_at: &str,
) -> Value {
    let source_client = record
        .get("sourceClient")
        .or_else(|| session.get("sourceClient"))
        .or_else(|| session.get("sourceTool"))
        .or_else(|| record.get("agentAdapterId"))
        .cloned()
        .unwrap_or_else(|| json!(""));
    json!({
        "archive_key": archive_key,
        "source_tool": source_client.clone(),
        "source_client": source_client,
        "source_client_label": record.get("sourceClientLabel").or_else(|| session.get("sourceClientLabel")).cloned().unwrap_or_else(|| json!("")),
        "host_app": record.get("hostApp").or_else(|| session.get("hostApp")).cloned().unwrap_or_else(|| json!("")),
        "host_app_label": record.get("hostAppLabel").or_else(|| session.get("hostAppLabel")).cloned().unwrap_or_else(|| json!("")),
        "source_label": record.get("sourceLabel").or_else(|| session.get("sourceLabel")).cloned().unwrap_or_else(|| json!("")),
        "adapter_id": record.get("agentAdapterId").or_else(|| session.get("adapterId")).cloned().unwrap_or_else(|| json!("")),
        "title": record.get("title").or_else(|| session.get("title")).cloned().unwrap_or_else(|| json!("")),
        "source_path": record.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "native_session_id": session.get("nativeSessionId").cloned().unwrap_or_else(|| json!("")),
        "snapshot_id": record.get("snapshotId").cloned().unwrap_or_else(|| json!("")),
        "snapshot_path": record.get("snapshotPath").cloned().unwrap_or_else(|| json!("")),
        "semantic_document_path": record.get("semanticDocumentPath").cloned().unwrap_or_else(|| json!("")),
        "semantic_markdown_path": record.get("semanticMarkdownPath").cloned().unwrap_or_else(|| json!("")),
        "semantic_content_hash": record.get("semanticContentHash").cloned().unwrap_or_else(|| json!("")),
        "raw_content_path": record.get("rawContentPath").cloned().unwrap_or_else(|| json!("")),
        "raw_export_kind": record.get("rawExportKind").cloned().unwrap_or_else(|| json!("")),
        "content_fingerprint": record.get("rawContentHash").cloned().unwrap_or_else(|| json!("")),
        "raw_content_bytes": record.get("rawContentBytes").cloned().unwrap_or_else(|| json!(0)),
        "matched_terms": profile_match.matched_terms.clone(),
        "confidence": profile_match.confidence,
        "match_reason": profile_match.reason,
        "archive_status": archive_status,
        "source_modified_at": session.get("updatedAt").cloned().unwrap_or_else(|| json!("")),
        "refreshed_at": refreshed_at
    })
}

fn archive_match_record(archive_key: &str, session: &Value, profile_match: &ProfileMatch) -> Value {
    let source_client = session
        .get("sourceClient")
        .or_else(|| session.get("sourceTool"))
        .or_else(|| session.get("adapterId"))
        .or_else(|| session.get("agentId"))
        .cloned()
        .unwrap_or_else(|| json!(""));
    json!({
        "archive_key": archive_key,
        "candidate_id": candidate_id(session).unwrap_or_default(),
        "source_tool": source_client.clone(),
        "source_client": source_client,
        "source_client_label": session.get("sourceClientLabel").cloned().unwrap_or_else(|| json!("")),
        "host_app": session.get("hostApp").cloned().unwrap_or_else(|| json!("")),
        "host_app_label": session.get("hostAppLabel").cloned().unwrap_or_else(|| json!("")),
        "source_label": session.get("sourceLabel").cloned().unwrap_or_else(|| json!("")),
        "adapter_id": session.get("adapterId").or_else(|| session.get("agentId")).cloned().unwrap_or_else(|| json!("")),
        "source_path": session.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "native_session_id": session.get("nativeSessionId").cloned().unwrap_or_else(|| json!("")),
        "matched_terms": profile_match.matched_terms.clone(),
        "confidence": profile_match.confidence,
        "reason": profile_match.reason
    })
}

fn read_index_records(path: &Path) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(path)?;
    let mut records = Vec::<Value>::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        records.push(serde_json::from_str(trimmed)?);
    }
    Ok(records)
}

fn index_records_by_archive_key(records: &[Value]) -> BTreeMap<String, Value> {
    records
        .iter()
        .filter_map(|record| {
            record
                .get("archive_key")
                .and_then(Value::as_str)
                .map(|key| (key.to_string(), record.clone()))
        })
        .collect()
}

fn append_preserved_index_records(
    previous_index: &[Value],
    current_keys: &BTreeSet<String>,
    index_records: &mut Vec<Value>,
) {
    for record in previous_index {
        let archive_key = record
            .get("archive_key")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if archive_key.is_empty() || current_keys.contains(archive_key) {
            continue;
        }
        if record
            .get("source_path")
            .and_then(Value::as_str)
            .map(excluded_archive_source_path)
            .unwrap_or(false)
        {
            continue;
        }
        let mut preserved = record.as_object().cloned().unwrap_or_default();
        preserved.insert("archive_status".to_string(), json!("preserved"));
        preserved.insert("preserved_at".to_string(), json!(timestamp_rfc3339()));
        if let Some(source_path) = preserved.get("source_path").and_then(Value::as_str) {
            if !source_path.is_empty() && !Path::new(source_path).exists() {
                preserved.insert("source_status".to_string(), json!("missing_source"));
            }
        }
        index_records.push(Value::Object(preserved));
    }
}

fn excluded_archive_source_path(source_path: &str) -> bool {
    Path::new(source_path)
        .components()
        .filter_map(|component| component.as_os_str().to_str())
        .any(|name| {
            matches!(
                name,
                "node_modules" | ".git" | "target" | "build" | "dist" | ".next"
            )
        })
}

fn prune_excluded_unindexed_snapshots(
    collection_dir: &Path,
    index_records: &[Value],
) -> Result<()> {
    let indexed_snapshot_paths = index_records
        .iter()
        .filter_map(|record| record.get("snapshot_path").and_then(Value::as_str))
        .map(str::to_string)
        .collect::<BTreeSet<_>>();
    let conversations_dir = collection_dir.join("conversations");
    if !conversations_dir.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(&conversations_dir)? {
        let entry = entry?;
        let snapshot_path = entry.path().join(SNAPSHOT_JSON);
        if !snapshot_path.exists()
            || indexed_snapshot_paths.contains(display_path(&snapshot_path).as_str())
        {
            continue;
        }
        let snapshot = read_json_or_default(&snapshot_path, || json!({}))?;
        if snapshot
            .get("sourcePath")
            .and_then(Value::as_str)
            .map(excluded_archive_source_path)
            .unwrap_or(false)
        {
            fs::remove_dir_all(entry.path())?;
        }
    }
    Ok(())
}

fn write_jsonl(path: &Path, records: &[Value]) -> Result<()> {
    let mut lines = Vec::<String>::new();
    for record in records {
        lines.push(serde_json::to_string(record)?);
    }
    let content = if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    };
    atomic_write_text(path, &content)
}

fn validate_archive_collection(
    collection_dir: &Path,
    index_records: &[Value],
    profile: &ArchiveProfile,
) -> Result<Value> {
    let mut issues = Vec::<Value>::new();
    let mut archive_keys = BTreeMap::<String, usize>::new();
    let mut fingerprints = BTreeMap::<String, usize>::new();
    let mut indexed_snapshot_paths = BTreeSet::<String>::new();
    let mut total_bytes = 0u64;

    for record in index_records {
        let archive_key = record
            .get("archive_key")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if archive_key.is_empty() {
            issues.push(json!({"type": "missing_archive_key", "severity": "error"}));
        } else {
            *archive_keys.entry(archive_key).or_insert(0) += 1;
        }
        let fingerprint = record
            .get("content_fingerprint")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if fingerprint.is_empty() {
            issues.push(json!({
                "type": "missing_fingerprint",
                "severity": "error",
                "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!(""))
            }));
        } else {
            *fingerprints.entry(fingerprint.clone()).or_insert(0) += 1;
        }
        for key in [
            "snapshot_path",
            "raw_content_path",
            "semantic_document_path",
            "semantic_markdown_path",
        ] {
            let path = record.get(key).and_then(Value::as_str).unwrap_or_default();
            if path.is_empty() || !Path::new(path).exists() {
                issues.push(json!({
                    "type": if key.starts_with("semantic_") {
                        "missing_semantic_document"
                    } else {
                        "missing_file"
                    },
                    "severity": "error",
                    "field": key,
                    "path": path,
                    "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!(""))
                }));
            }
            if key == "snapshot_path" && !path.is_empty() {
                indexed_snapshot_paths.insert(path.to_string());
            }
        }
        if let Some(semantic_hash) = record
            .get("semantic_content_hash")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            let semantic_path = record
                .get("semantic_document_path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !semantic_path.is_empty() && Path::new(semantic_path).exists() {
                let content = fs::read_to_string(semantic_path)?;
                let actual = hash_text(&content.trim_end_matches('\n'));
                // materialize writes pretty JSON + trailing newline; compare both forms.
                let actual_raw = hash_text(&content);
                if actual != semantic_hash && actual_raw != semantic_hash {
                    issues.push(json!({
                        "type": "stale_semantic_hash",
                        "severity": "error",
                        "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!("")),
                        "path": semantic_path,
                        "expectedFingerprint": semantic_hash,
                        "actualFingerprint": actual_raw
                    }));
                }
                if let Ok(semantic_value) = serde_json::from_str::<Value>(&content) {
                    if let Err(error) =
                        crate::domain::conversation_semantic::validate_semantic_conversation(
                            &semantic_value,
                        )
                    {
                        issues.push(json!({
                            "type": "invalid_semantic_document",
                            "severity": "error",
                            "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!("")),
                            "path": semantic_path,
                            "detail": error.to_string()
                        }));
                    }
                    let thread_empty = semantic_value
                        .get("thread")
                        .and_then(Value::as_array)
                        .map(|items| items.is_empty())
                        .unwrap_or(true);
                    let execution_empty = semantic_value
                        .get("execution")
                        .and_then(Value::as_array)
                        .map(|items| items.is_empty())
                        .unwrap_or(true);
                    if thread_empty
                        && execution_empty
                        && record
                            .get("match_reason")
                            .and_then(Value::as_str)
                            .is_some_and(|reason| reason.contains("metadata"))
                    {
                        issues.push(json!({
                            "type": "metadata_only_false_positive",
                            "severity": "warning",
                            "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!("")),
                            "path": semantic_path
                        }));
                    }
                }
            }
        }
        if let Some(bytes) = record.get("raw_content_bytes").and_then(Value::as_u64) {
            total_bytes += bytes;
            let raw_path = record
                .get("raw_content_path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !raw_path.is_empty() && Path::new(raw_path).exists() {
                let actual_bytes = fs::metadata(raw_path)?.len();
                if actual_bytes != bytes {
                    issues.push(json!({
                        "type": "raw_content_size_mismatch",
                        "severity": "error",
                        "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!("")),
                        "path": raw_path,
                        "expectedBytes": bytes,
                        "actualBytes": actual_bytes
                    }));
                }
            }
        }
        if !fingerprint.is_empty() {
            let raw_path = record
                .get("raw_content_path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !raw_path.is_empty() && Path::new(raw_path).exists() {
                let content = fs::read(raw_path)?;
                let actual_fingerprint = hash_bytes(&content);
                if actual_fingerprint != fingerprint {
                    issues.push(json!({
                        "type": "raw_content_fingerprint_mismatch",
                        "severity": "error",
                        "archive_key": record.get("archive_key").cloned().unwrap_or_else(|| json!("")),
                        "path": raw_path,
                        "expectedFingerprint": fingerprint,
                        "actualFingerprint": actual_fingerprint
                    }));
                }
            }
        }
    }

    for (key, count) in archive_keys {
        if count > 1 {
            issues.push(json!({
                "type": "duplicate_archive_key",
                "severity": "error",
                "archive_key": key,
                "count": count
            }));
        }
    }
    for (fingerprint, count) in fingerprints {
        if count > 1 {
            issues.push(json!({
                "type": "duplicate_content_fingerprint",
                "severity": "warning",
                "content_fingerprint": fingerprint,
                "count": count
            }));
        }
    }
    let conversations_dir = collection_dir.join("conversations");
    if conversations_dir.exists() {
        for entry in fs::read_dir(&conversations_dir)? {
            let entry = entry?;
            let snapshot_path = entry.path().join(SNAPSHOT_JSON);
            if snapshot_path.exists()
                && !indexed_snapshot_paths.contains(display_path(&snapshot_path).as_str())
            {
                issues.push(json!({
                    "type": "stale_unindexed",
                    "severity": "warning",
                    "snapshot_path": display_path(&snapshot_path)
                }));
            }
        }
    }
    let baseline = baseline_coverage(profile, index_records, total_bytes)?;
    let error_count = issues
        .iter()
        .filter(|issue| issue.get("severity").and_then(Value::as_str) == Some("error"))
        .count();
    let warning_count = issues.len().saturating_sub(error_count);
    let health_status = if error_count > 0 {
        "failed"
    } else if warning_count > 0 {
        "warning"
    } else {
        "ok"
    };
    Ok(json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "profileId": profile.profile_id,
        "checkedAt": timestamp_rfc3339(),
        "healthStatus": health_status,
        "recordCount": index_records.len(),
        "rawContentBytes": total_bytes,
        "errorCount": error_count,
        "warningCount": warning_count,
        "issues": issues,
        "baseline": baseline
    }))
}

fn baseline_coverage(
    profile: &ArchiveProfile,
    index_records: &[Value],
    total_bytes: u64,
) -> Result<Value> {
    let Some(path) = &profile.baseline_index_path else {
        return Ok(json!({"configured": false}));
    };
    if !path.exists() {
        return Ok(json!({
            "configured": true,
            "status": "missing_baseline",
            "baselineIndexPath": display_path(path)
        }));
    }
    let records = read_index_records(path)?;
    let baseline_count = records.len() as u64;
    let baseline_bytes = records.iter().filter_map(record_numeric_bytes).sum::<u64>();
    let current_count = index_records.len() as u64;
    Ok(json!({
        "configured": true,
        "status": "compared",
        "baselineIndexPath": display_path(path),
        "baselineCount": baseline_count,
        "currentCount": current_count,
        "countCoverage": if baseline_count == 0 { 1.0 } else { current_count as f64 / baseline_count as f64 },
        "baselineBytes": baseline_bytes,
        "currentBytes": total_bytes,
        "byteCoverage": if baseline_bytes == 0 { 1.0 } else { total_bytes as f64 / baseline_bytes as f64 }
    }))
}

fn record_numeric_bytes(record: &Value) -> Option<u64> {
    for key in [
        "raw_content_bytes",
        "rawContentBytes",
        "bytes",
        "contentBytes",
        "conversation_bytes",
    ] {
        if let Some(value) = record.get(key).and_then(Value::as_u64) {
            return Some(value);
        }
    }
    None
}

fn conversation_index_markdown(
    profile: &ArchiveProfile,
    index_records: &[Value],
    validation: &Value,
) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "# Conversation Index: {}\n\n",
        profile.display_name
    ));
    out.push_str(&format!(
        "- Profile: `{}`\n- Records: {}\n- Health: `{}`\n\n",
        profile.profile_id,
        index_records.len(),
        validation
            .get("healthStatus")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    ));
    out.push_str("| Title | Source | Adapter | Confidence | Status | Semantic |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- |\n");
    for record in index_records {
        out.push_str(&format!(
            "| {} | `{}` | `{}` | `{}` | `{}` | `{}` |\n",
            markdown_cell(
                record
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or_else(|| {
                        record
                            .get("archive_key")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                    })
            ),
            record
                .get("source_label")
                .or_else(|| record.get("source_tool"))
                .and_then(Value::as_str)
                .unwrap_or(""),
            record
                .get("adapter_id")
                .and_then(Value::as_str)
                .unwrap_or(""),
            record
                .get("confidence")
                .and_then(Value::as_str)
                .unwrap_or(""),
            record
                .get("archive_status")
                .and_then(Value::as_str)
                .unwrap_or(""),
            record
                .get("semantic_markdown_path")
                .or_else(|| record.get("semantic_document_path"))
                .and_then(Value::as_str)
                .unwrap_or("")
        ));
    }
    out
}

fn markdown_cell(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('|', "\\|")
}

fn archive_summary_markdown(
    profile: &ArchiveProfile,
    root: &Path,
    discovery: &DiscoveryResult,
    index_records: &[Value],
    validation: &Value,
) -> String {
    let mut by_source = BTreeMap::<String, usize>::new();
    for record in index_records {
        let source = record
            .get("source_label")
            .or_else(|| record.get("source_tool"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        *by_source.entry(source).or_insert(0) += 1;
    }
    let mut out = String::new();
    out.push_str(&format!(
        "# Conversation Archive Summary: {}\n\n",
        profile.display_name
    ));
    out.push_str(&format!(
        "- Profile: `{}`\n- Archive root: `{}`\n- Candidates scanned: {}\n- Archived records: {}\n- Health: `{}`\n\n",
        profile.profile_id,
        display_path(root),
        discovery.candidates.len(),
        index_records.len(),
        validation.get("healthStatus").and_then(Value::as_str).unwrap_or("unknown")
    ));
    out.push_str("## By Source\n\n");
    for (source, count) in by_source {
        out.push_str(&format!("- `{}`: {}\n", source, count));
    }
    out.push_str("\n## Source Coverage\n\n");
    for source in &discovery.source_summaries {
        out.push_str(&format!(
            "- `{}` `{}`: {} sessions, {} files seen\n",
            source.get("agentId").and_then(Value::as_str).unwrap_or(""),
            source.get("scope").and_then(Value::as_str).unwrap_or(""),
            source
                .get("sessionCount")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            source.get("filesSeen").and_then(Value::as_u64).unwrap_or(0)
        ));
    }
    out
}

fn archive_workflow_diagnostics(
    discovery: &DiscoveryResult,
    validation: &Value,
    index_count: usize,
) -> Vec<Value> {
    let mut diagnostics = discovery.diagnostics.clone();
    diagnostics.push(json!({
        "stage": "archive_profile_matching",
        "status": "completed",
        "indexCount": index_count,
        "candidateCount": discovery.candidates.len()
    }));
    diagnostics.push(json!({
        "stage": "archive_validation",
        "status": validation.get("healthStatus").cloned().unwrap_or_else(|| json!("unknown")),
        "errorCount": validation.get("errorCount").cloned().unwrap_or_else(|| json!(0)),
        "warningCount": validation.get("warningCount").cloned().unwrap_or_else(|| json!(0))
    }));
    diagnostics
}

fn curation_state(store: &ClientStateStore, params: &Value) -> Result<Value> {
    if curation_result(params)?.is_some() {
        return Ok(json!({
            "enabled": true,
            "status": "structured_result_provided",
            "mode": "structured-result"
        }));
    }
    let enabled = param_bool(params, "curation").unwrap_or(true);
    if !enabled {
        return Ok(json!({
            "enabled": false,
            "status": "disabled",
            "mode": "deterministic"
        }));
    }
    let settings = store.read_collection(SETTINGS_COLLECTION)?;
    let preferred = settings
        .get("preferredSnapshotCurator")
        .cloned()
        .unwrap_or_else(|| json!(null));
    if preferred.is_null() {
        return Ok(json!({
            "enabled": true,
            "status": "not_configured",
            "mode": "deterministic"
        }));
    }
    let target = preferred
        .get("target")
        .or_else(|| preferred.get("agent"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let bridge = bridge_state_for(store, target)?;
    if bridge
        .get("status")
        .and_then(Value::as_str)
        .map(|status| status == "verified")
        .unwrap_or(false)
    {
        return Ok(json!({
            "enabled": true,
            "status": "available",
            "mode": "structured-result-required",
            "preferredSnapshotCurator": preferred,
            "bridge": bridge
        }));
    }
    Ok(json!({
        "enabled": true,
        "status": "bridge_missing",
        "mode": "deterministic",
        "preferredSnapshotCurator": preferred
    }))
}

fn invoke_preferred_curator(
    store: &ClientStateStore,
    params: &Value,
    topic: &str,
    topic_key: &str,
    discovery: &DiscoveryResult,
    curation: &Value,
) -> Result<CuratorInvocation> {
    let preferred = curation
        .get("preferredSnapshotCurator")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let target = preferred
        .get("target")
        .or_else(|| preferred.get("agent"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if target.trim().is_empty() {
        return Ok(CuratorInvocation {
            curation: curator_fallback_state(
                curation,
                "curator_failed",
                json!({"stage": "curator_task_dispatch", "status": "failed", "message": "preferred snapshot curator target is empty"}),
                None,
            ),
            structured_result: None,
        });
    }

    let session_id = format!(
        "curation-{}-{}",
        timestamp_stamp(),
        &hash_text(&(topic_key.to_string() + &target + &timestamp_stamp()))[..12]
    );
    let created_at = timestamp_rfc3339();
    let read_budget = read_budget_for_curator(params, &preferred);
    let (session, session_path) = create_curation_session(
        store,
        &session_id,
        topic,
        topic_key,
        &created_at,
        read_budget,
        discovery,
    )?;
    let prompt = curator_task_prompt(topic, &session);
    let mut runtime_params = Map::<String, Value>::new();
    runtime_params.insert("agent".to_string(), json!(target));
    runtime_params.insert("text".to_string(), json!(prompt));
    copy_preferred_runtime_field(params, &mut runtime_params, "binary");
    copy_preferred_runtime_field(&preferred, &mut runtime_params, "cwd");
    copy_preferred_runtime_field(&preferred, &mut runtime_params, "workingDirectory");
    copy_preferred_runtime_field(&preferred, &mut runtime_params, "timeoutMs");
    copy_preferred_runtime_field(&preferred, &mut runtime_params, "maxStdoutBytes");
    copy_preferred_runtime_field(&preferred, &mut runtime_params, "maxStderrBytes");

    let dispatch = match runtime_adapters::send_message(&Value::Object(runtime_params)) {
        Ok(result) => result,
        Err(error) => {
            return Ok(CuratorInvocation {
                curation: curator_fallback_state(
                    curation,
                    "curator_failed",
                    json!({
                        "stage": "curator_task_dispatch",
                        "status": "failed",
                        "curationSessionId": session_id,
                        "sessionPath": display_path(&session_path),
                        "message": error.to_string()
                    }),
                    Some(&session_id),
                ),
                structured_result: None,
            });
        }
    };

    let session_after = load_curation_session_by_id(store, &session_id)?;
    if let Some(result) = session_after
        .get("submittedResult")
        .filter(|value| !value.is_null())
        .cloned()
    {
        validate_curation_result_for_session(&session_after, &result)?;
        return Ok(CuratorInvocation {
            curation: curator_success_state(
                curation,
                "session_result_submitted",
                &session_id,
                &session_path,
                &dispatch,
            ),
            structured_result: Some(result),
        });
    }

    if let Some(result) = structured_result_from_runtime_output(&dispatch) {
        match validate_curation_result_for_session(&session_after, &result) {
            Ok(()) => {
                return Ok(CuratorInvocation {
                    curation: curator_success_state(
                        curation,
                        "runtime_output_structured_result",
                        &session_id,
                        &session_path,
                        &dispatch,
                    ),
                    structured_result: Some(result),
                });
            }
            Err(error) => {
                return Ok(CuratorInvocation {
                    curation: curator_fallback_state(
                        curation,
                        "invalid_structured_result",
                        json!({
                            "stage": "structured_result_validation",
                            "status": "failed",
                            "curationSessionId": session_id,
                            "sessionPath": display_path(&session_path),
                            "message": error.to_string(),
                            "dispatch": dispatch_summary(&dispatch)
                        }),
                        Some(&session_id),
                    ),
                    structured_result: None,
                });
            }
        }
    }

    Ok(CuratorInvocation {
        curation: curator_fallback_state(
            curation,
            "curator_no_structured_result",
            json!({
                "stage": "structured_result_validation",
                "status": "no_structured_result",
                "curationSessionId": session_id,
                "sessionPath": display_path(&session_path),
                "dispatch": dispatch_summary(&dispatch)
            }),
            Some(&session_id),
        ),
        structured_result: None,
    })
}

fn read_budget_for_curator(params: &Value, preferred: &Value) -> usize {
    text_param(params, &["readBudget", "readBudgetItems"])
        .or_else(|| text_value(preferred, "readBudget"))
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(12)
}

fn copy_preferred_runtime_field(preferred: &Value, target: &mut Map<String, Value>, key: &str) {
    if let Some(value) = preferred.get(key) {
        if !value.is_null() {
            target.insert(key.to_string(), value.clone());
        }
    }
}

fn curator_task_prompt(topic: &str, session: &Value) -> String {
    let session_id = text_value(session, "curationSessionId").unwrap_or_default();
    let candidate_count = session
        .get("candidateBriefs")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let read_budget = session
        .get("readBudget")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    format!(
        "You are LicoLite's Preferred Snapshot Curator for a local native conversation snapshot run.\n\
Topic: {topic}\n\
Curation session id: {session_id}\n\
Candidate briefs available: {candidate_count}\n\
Full-content expansion budget: {read_budget}\n\n\
Use only the LicoLite Snapshot Curation Bridge tools for authoritative selection:\n\
1. snapshot.candidates.list with this curationSessionId.\n\
2. snapshot.candidate.expand only when a brief is insufficient.\n\
3. snapshot.curation.submit_result with selectedCandidateIds, rejectedCandidateIds, labelsByCandidateId, groupsByCandidateId, summariesByCandidateId, and reasonsByCandidateId.\n\n\
Do not write snapshot files or modify collection manifests. If you cannot use the bridge tools, return a JSON Structured Curation Result with the same fields. Natural-language output is diagnostic only."
    )
}

fn structured_result_from_runtime_output(dispatch: &Value) -> Option<Value> {
    let output = dispatch.get("output").and_then(Value::as_str)?.trim();
    if output.is_empty() {
        return None;
    }
    if let Ok(value) = serde_json::from_str::<Value>(output) {
        if looks_like_structured_result(&value) {
            return Some(value);
        }
        if let Some(result) = value.get("structuredCurationResult") {
            if looks_like_structured_result(result) {
                return Some(result.clone());
            }
        }
    }
    None
}

fn looks_like_structured_result(value: &Value) -> bool {
    value
        .get("selectedCandidateIds")
        .or_else(|| value.get("selected"))
        .and_then(Value::as_array)
        .is_some()
}

fn curator_success_state(
    base: &Value,
    status: &str,
    session_id: &str,
    session_path: &Path,
    dispatch: &Value,
) -> Value {
    let mut object = base.as_object().cloned().unwrap_or_default();
    object.insert("status".to_string(), json!(status));
    object.insert("mode".to_string(), json!("preferred-curator"));
    object.insert("curationSessionId".to_string(), json!(session_id));
    object.insert("sessionPath".to_string(), json!(display_path(session_path)));
    object.insert("dispatch".to_string(), dispatch_summary(dispatch));
    Value::Object(object)
}

fn curator_fallback_state(
    base: &Value,
    status: &str,
    diagnostic: Value,
    session_id: Option<&str>,
) -> Value {
    let mut object = base.as_object().cloned().unwrap_or_default();
    object.insert("status".to_string(), json!(status));
    object.insert("mode".to_string(), json!("deterministic"));
    if let Some(session_id) = session_id {
        object.insert("curationSessionId".to_string(), json!(session_id));
    }
    object.insert("diagnostics".to_string(), json!([diagnostic]));
    Value::Object(object)
}

fn dispatch_summary(dispatch: &Value) -> Value {
    json!({
        "ok": dispatch.get("ok").cloned().unwrap_or_else(|| json!(false)),
        "mode": dispatch.get("mode").cloned().unwrap_or_else(|| json!("")),
        "agentId": dispatch.get("agentId").cloned().unwrap_or_else(|| json!("")),
        "runtimeProtocol": dispatch.get("runtimeProtocol").cloned().unwrap_or_else(|| json!("")),
        "statusCode": dispatch.get("statusCode").cloned().unwrap_or_else(|| json!(null)),
        "stdoutTruncated": dispatch.get("stdoutTruncated").cloned().unwrap_or_else(|| json!(false)),
        "stderrTruncated": dispatch.get("stderrTruncated").cloned().unwrap_or_else(|| json!(false)),
        "outputPreview": dispatch.get("output").and_then(Value::as_str).map(|value| truncate_chars(value, 600)).unwrap_or_default(),
        "stderrPreview": dispatch.get("stderr").and_then(Value::as_str).map(|value| truncate_chars(value, 600)).unwrap_or_default()
    })
}

fn bridge_state_for(store: &ClientStateStore, target: &str) -> Result<Value> {
    let document = store.read_collection(BRIDGES_COLLECTION)?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("target").and_then(Value::as_str) == Some(target))
                .cloned()
        })
        .unwrap_or_else(|| json!({})))
}

fn upsert_bridge_state(store: &ClientStateStore, target: &str, state: Value) -> Result<()> {
    let mut document = store
        .read_collection(BRIDGES_COLLECTION)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    let mut items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(existing) = items
        .iter_mut()
        .find(|item| item.get("target").and_then(Value::as_str) == Some(target))
    {
        *existing = state;
    } else {
        items.push(state);
    }
    document.insert("items".to_string(), Value::Array(items));
    store.write_collection(BRIDGES_COLLECTION, Value::Object(document))?;
    Ok(())
}

fn bridge_config(target: &str) -> Value {
    json!({
        "schemaVersion": COLLECTION_SCHEMA_VERSION,
        "managedBy": "LicoLite",
        "bridgeId": format!("snapshot-curation-{}", sanitize_id(target)),
        "target": target,
        "description": "Local Snapshot Curation Bridge for native conversation archives.",
        "tools": [
            "snapshot.curation.start",
            "snapshot.candidates.list",
            "snapshot.candidate.expand",
            "snapshot.curation.submit_result",
            "snapshot.profiles.list",
            "snapshot.archive.run",
            "snapshot.archive.report"
        ]
    })
}

fn apply_bridge_config(
    path: &Path,
    current: &str,
    bridge: &Value,
    params: &Value,
) -> Result<String> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "toml" => apply_toml_bridge(current, bridge),
        "json" => apply_json_bridge(current, bridge),
        "jsonc" => {
            if !param_bool(params, "explicitFormatRewrite").unwrap_or(false)
                && (current.contains("//") || current.contains("/*"))
            {
                return Err(anyhow!(
                    "format_loss_confirmation_required: set --explicit-format-rewrite true to rewrite JSONC without comments"
                ));
            }
            apply_json_bridge(strip_jsonc_comments(current).as_str(), bridge)
        }
        _ => apply_json_bridge(current, bridge),
    }
}

fn apply_json_bridge(current: &str, bridge: &Value) -> Result<String> {
    let mut value = if current.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str::<Value>(current)?
    };
    let object = value
        .as_object_mut()
        .ok_or_else(|| anyhow!("target bridge config root must be a JSON object"))?;
    object.insert(BRIDGE_CONFIG_KEY.to_string(), bridge.clone());
    Ok(format!("{}\n", serde_json::to_string_pretty(&value)?))
}

fn apply_toml_bridge(current: &str, bridge: &Value) -> Result<String> {
    let mut value = if current.trim().is_empty() {
        toml::Value::Table(toml::map::Map::new())
    } else {
        current.parse::<toml::Value>()?
    };
    let table = value
        .as_table_mut()
        .ok_or_else(|| anyhow!("target bridge config root must be a TOML table"))?;
    table.insert(BRIDGE_CONFIG_KEY.to_string(), json_to_toml(bridge));
    Ok(format!("{}\n", toml::to_string_pretty(&value)?))
}

fn verify_bridge_config(path: &Path) -> Result<bool> {
    let raw = fs::read_to_string(path).unwrap_or_default();
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if extension == "toml" {
        let value = raw.parse::<toml::Value>()?;
        return Ok(value.get(BRIDGE_CONFIG_KEY).is_some());
    }
    let value = serde_json::from_str::<Value>(&strip_jsonc_comments(&raw))?;
    Ok(value.get(BRIDGE_CONFIG_KEY).is_some())
}

fn curation_result(params: &Value) -> Result<Option<Value>> {
    if let Some(raw) = text_param(params, &["curationResultJson"]) {
        if !raw.trim().is_empty() {
            return Ok(Some(serde_json::from_str(&raw)?));
        }
    }
    if let Some(path) = text_param(params, &["curationResultFile"]) {
        if !path.trim().is_empty() {
            return Ok(Some(serde_json::from_str(&fs::read_to_string(
                expand_home(&path),
            )?)?));
        }
    }
    Ok(None)
}

fn filter_json_session(value: &Value, native_id: &str) -> Option<Value> {
    if extract_native_session_id(value).as_deref() == Some(native_id) || native_id == "file" {
        return Some(value.clone());
    }
    let object = value.as_object()?;
    for key in ["sessions", "conversations", "chats", "chatSessions"] {
        if let Some(items) = object.get(key).and_then(Value::as_array) {
            let selected = items
                .iter()
                .filter(|item| extract_native_session_id(item).as_deref() == Some(native_id))
                .cloned()
                .collect::<Vec<_>>();
            if !selected.is_empty() {
                let mut out = Map::<String, Value>::new();
                out.insert(key.to_string(), Value::Array(selected));
                return Some(Value::Object(out));
            }
        }
    }
    None
}

fn topic_key(topic: &str) -> Option<String> {
    let normalized = normalize_match_text(topic).trim_matches('-').to_string();
    if normalized.is_empty() {
        None
    } else if normalized.chars().count() <= 96 {
        Some(normalized)
    } else {
        let digest = hash_text(&normalized);
        Some(format!(
            "{}-{}",
            normalized.chars().take(72).collect::<String>(),
            &digest[..16]
        ))
    }
}

fn normalize_match_text(value: &str) -> String {
    let mut out = String::new();
    let mut separator = false;
    for ch in value.chars().filter_map(normalize_width) {
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

fn compact_identity_key(value: &str) -> String {
    normalize_match_text(value)
        .chars()
        .filter(|ch| *ch != '-')
        .collect()
}

fn normalized_contains_identity_term(normalized: &str, term: &str) -> bool {
    if term.is_empty() {
        return false;
    }
    normalized.match_indices(term).any(|(index, _)| {
        let before = normalized[..index].chars().next_back();
        let after = normalized[index + term.len()..].chars().next();
        identity_boundary(before) && identity_boundary(after)
    })
}

fn identity_boundary(ch: Option<char>) -> bool {
    ch.map(|ch| !ch.is_ascii_alphanumeric()).unwrap_or(true)
}

fn normalize_width(ch: char) -> Option<char> {
    if ch == '\u{3000}' {
        return Some(' ');
    }
    let value = ch as u32;
    if (0xFF01..=0xFF5E).contains(&value) {
        return char::from_u32(value - 0xFEE0);
    }
    Some(ch)
}

fn native_identity(session: &Value) -> String {
    let source_client = text_value(session, "sourceClient")
        .or_else(|| text_value(session, "sourceTool"))
        .or_else(|| text_value(session, "adapterId"))
        .or_else(|| text_value(session, "agentId"))
        .unwrap_or_else(|| "unknown".to_string());
    let native_id = text_value(session, "nativeSessionId").unwrap_or_else(|| "file".to_string());
    let source_path = text_value(session, "sourcePath").unwrap_or_default();
    format!("{}:{}:{}", source_client, source_path, native_id)
}

fn candidate_id(value: &Value) -> Option<String> {
    text_value(value, "id").filter(|id| !id.trim().is_empty())
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
            "id",
        ],
    )
    .filter(|value| !value.trim().is_empty())
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
    None
}

fn text_value(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn usize_param(params: &Value, keys: &[&str]) -> Option<usize> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| match value {
            Value::Number(number) => number
                .as_u64()
                .and_then(|value| usize::try_from(value).ok()),
            Value::String(text) => text.trim().parse::<usize>().ok(),
            _ => None,
        })
    })
}

fn string_list_value(value: &Value, key: &str) -> Vec<String> {
    match value.get(key) {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .flat_map(split_path_list)
            .collect(),
        Some(Value::String(value)) => split_path_list(value),
        _ => Vec::new(),
    }
}

fn merge_params(base: &Value, overlay: Value) -> Value {
    let mut object = base.as_object().cloned().unwrap_or_default();
    if let Some(overlay) = overlay.as_object() {
        for (key, value) in overlay {
            object.insert(key.clone(), value.clone());
        }
    }
    Value::Object(object)
}

fn history_roots_from_value(value: Option<&Value>) -> Vec<PathBuf> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .flat_map(split_path_list)
            .map(|path| expand_home(&path))
            .collect(),
        Some(Value::String(value)) => split_path_list(value)
            .into_iter()
            .map(|path| expand_home(&path))
            .collect(),
        _ => Vec::new(),
    }
}

fn split_path_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn normalize_agent_alias(agent: &str) -> String {
    match agent.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude-code" => "claude-code",
        "vscode" | "vs-code" => "code",
        "copilot" | "github-copilot" => "copilot",
        "hermes" | "hermes-agent" => "hermes",
        "kilo" | "kilo-code" => "kilo-code",
        "kimi-code" | "kimicode" => "kimi-code",
        "kimi" | "moonshot" => "kimi",
        "pi" | "pi-agent" | "pi-coding-agent" => "pi",
        other => other,
    }
    .to_string()
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

fn object_map(value: Option<&Value>) -> BTreeMap<String, Value> {
    value
        .and_then(Value::as_object)
        .map(|object| {
            object
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        })
        .unwrap_or_default()
}

fn client_state_store(params: &Value) -> Result<ClientStateStore> {
    if let Some(root) = text_param(params, &["stateRoot", "clientStateRoot"]) {
        if !root.is_empty() {
            return ClientStateStore::new(expand_home(&root));
        }
    }
    if let Some(portable_dir) = text_param(params, &["portableDir"]) {
        if !portable_dir.is_empty() {
            return ClientStateStore::new(expand_home(&portable_dir).join("lico-client"));
        }
    }
    Ok(ClientStateStore::new(
        portable_data_dir()?.join("lico-client"),
    )?)
}

fn read_json_or_default<F>(path: &Path, default_value: F) -> Result<Value>
where
    F: FnOnce() -> Value,
{
    if !path.exists() {
        return Ok(default_value());
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(default_value());
    }
    Ok(serde_json::from_str(&raw)?)
}

fn atomic_write_json(path: &Path, value: &Value) -> Result<()> {
    atomic_write_text(path, &format!("{}\n", serde_json::to_string_pretty(value)?))
}

fn atomic_write_text(path: &Path, content: &str) -> Result<()> {
    atomic_write_private_text(path, content)
}

fn copy_dir_all(from: &Path, to: &Path) -> Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_all(&entry.path(), &target)?;
        } else if file_type.is_symlink() {
            // Skip symlinks — never follow them to external paths.
            continue;
        } else {
            // Copy only regular file content without following symlinks.
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn directory_is_empty(path: &Path) -> Result<bool> {
    if !path.exists() {
        return Ok(true);
    }
    Ok(fs::read_dir(path)?.next().is_none())
}

fn equivalent_paths(left: &Path, right: &Path) -> bool {
    if left == right {
        return true;
    }
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn existing_created_at(path: &Path) -> Option<String> {
    read_json_or_default(path, || json!({}))
        .ok()
        .and_then(|value| text_value(&value, "createdAt"))
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

fn home_dir() -> PathBuf {
    home_dir_from_env(|name| std::env::var_os(name))
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
    env_path_from(&|key| std::env::var_os(key), name)
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

fn xdg_config_dir() -> PathBuf {
    env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home_dir().join(".config"))
}

fn default_target_config_path(target: &str) -> Option<PathBuf> {
    let home = home_dir();
    match target {
        "codex" => Some(home.join(".codex").join("config.toml")),
        "opencode" => Some(home.join(".config").join("opencode").join("opencode.jsonc")),
        "antigravity" => Some(home.join(".gemini").join("settings.json")),
        "cursor" => Some(home.join("Library/Application Support/Cursor/User/settings.json")),
        "claude" | "claude-code" => Some(home.join(".claude.json")),
        "copilot" | "github-copilot" => {
            Some(home.join("Library/Application Support/Code/User/settings.json"))
        }
        "openclaw" => Some(home.join(".openclaw").join("config.json")),
        "kilo" | "kilo-code" => Some(home.join(".config").join("kilo").join("config.json")),
        "kimi-code" | "kimicode" => Some(home.join(".kimi-code").join("config.toml")),
        "pi" | "pi-agent" | "pi-coding-agent" => {
            Some(home.join(".pi").join("agent").join("settings.json"))
        }
        "kimi" | "moonshot" if cfg!(target_os = "macos") => Some(
            home.join("Library")
                .join("Application Support")
                .join("Kimi")
                .join("config.json"),
        ),
        "kimi" | "moonshot" if cfg!(windows) => {
            Some(appdata_dir().join("Kimi").join("config.json"))
        }
        "kimi" | "moonshot" => Some(home.join(".config").join("Kimi").join("config.json")),
        "hermes" | "hermes-agent" => Some(home.join(".hermes").join("config.json")),
        _ => Some(appdata_dir().join(target).join("settings.json")),
    }
}

fn strip_jsonc_comments(input: &str) -> String {
    let mut out = String::new();
    let mut chars = input.chars().peekable();
    let mut in_string = false;
    let mut escaped = false;
    while let Some(ch) = chars.next() {
        if in_string {
            out.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        if ch == '"' {
            in_string = true;
            out.push(ch);
            continue;
        }
        if ch == '/' && chars.peek() == Some(&'/') {
            chars.next();
            for next in chars.by_ref() {
                if next == '\n' {
                    out.push('\n');
                    break;
                }
            }
            continue;
        }
        if ch == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut previous = '\0';
            for next in chars.by_ref() {
                if previous == '*' && next == '/' {
                    break;
                }
                previous = next;
            }
            continue;
        }
        out.push(ch);
    }
    out
}

fn json_to_toml(value: &Value) -> toml::Value {
    match value {
        Value::Null => toml::Value::String(String::new()),
        Value::Bool(value) => toml::Value::Boolean(*value),
        Value::Number(value) => {
            if let Some(integer) = value.as_i64() {
                toml::Value::Integer(integer)
            } else if let Some(float) = value.as_f64() {
                toml::Value::Float(float)
            } else {
                toml::Value::String(value.to_string())
            }
        }
        Value::String(value) => toml::Value::String(value.clone()),
        Value::Array(items) => toml::Value::Array(items.iter().map(json_to_toml).collect()),
        Value::Object(object) => {
            let mut table = toml::map::Map::new();
            for (key, value) in object {
                table.insert(key.clone(), json_to_toml(value));
            }
            toml::Value::Table(table)
        }
    }
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

fn hash_parts(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.as_bytes());
        hasher.update(b"\n");
    }
    format!("{:x}", hasher.finalize())
}

fn hash_text(content: &str) -> String {
    hash_bytes(content.as_bytes())
}

fn hash_bytes(content: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content);
    format!("{:x}", hasher.finalize())
}

fn sanitize_id(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn truncate_chars(value: &str, limit: usize) -> String {
    if value.chars().count() <= limit {
        value.to_string()
    } else {
        format!("{}...", value.chars().take(limit).collect::<String>())
    }
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn timestamp_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn timestamp_stamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::process::Command as TestCommand;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn archive_home_uses_windows_userprofile_when_home_is_missing() {
        let resolved = home_dir_from_env(|name| match name {
            "USERPROFILE" => Some(OsString::from(r"C:\Profile\LicoLite")),
            _ => None,
        });

        assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
    }

    #[test]
    fn archive_home_uses_windows_drive_and_homepath_fallback() {
        let resolved = home_dir_from_env(|name| match name {
            "HOMEDRIVE" => Some(OsString::from("C:")),
            "HOMEPATH" => Some(OsString::from(r"\Profile\LicoLite")),
            _ => None,
        });

        assert_eq!(resolved, PathBuf::from(r"C:\Profile\LicoLite"));
    }

    #[test]
    fn archive_expand_home_accepts_windows_style_tilde_paths() {
        let expanded = expand_home_from(r"~\.codex\sessions", || {
            PathBuf::from(r"C:\Profile\LicoLite")
        });

        assert_eq!(
            expanded,
            PathBuf::from(r"C:\Profile\LicoLite").join(r".codex\sessions")
        );
    }

    #[test]
    fn topic_key_normalizes_case_space_width_and_separators() {
        assert_eq!(
            topic_key(" Codex＿Spark weekly limit ").unwrap(),
            "codex-spark-weekly-limit"
        );
        assert_eq!(topic_key("Ｃｏｄｅｘ　Spark").unwrap(), "codex-spark");
    }

    #[test]
    fn archive_keywords_dedupes_after_normalization() {
        let keywords = archive_keywords(&json!({
            "keywords": "OSysIt,osysit, OSYSIT "
        }))
        .unwrap();

        assert_eq!(keywords, vec!["OSysIt"]);
        let profile =
            derived_archive_profile(&keywords, Path::new("/tmp/archive"), &["codex".into()])
                .unwrap();
        assert_eq!(profile.profile_id, "osysit");
        assert_eq!(profile.collection_path_segments, vec!["osysit"]);
        assert_eq!(profile.canonical_names, vec!["OSysIt"]);
    }

    #[test]
    fn archive_keywords_create_one_profile_per_keyword() {
        let keywords = archive_keywords(&json!({
            "keywords": "LicoLite, Agent Studio, osysit"
        }))
        .unwrap();
        let profiles = derived_keyword_archive_profiles(
            &keywords,
            Path::new("/tmp/archive"),
            &["codex".into()],
        )
        .unwrap();

        assert_eq!(keywords, vec!["LicoLite", "Agent Studio", "osysit"]);
        assert_eq!(profiles.len(), 3);
        assert_eq!(profiles[0].collection_path_segments, vec!["licolite"]);
        assert_eq!(profiles[0].canonical_names, vec!["LicoLite"]);
        assert_eq!(profiles[1].collection_path_segments, vec!["agent-studio"]);
        assert_eq!(profiles[1].canonical_names, vec!["Agent Studio"]);
        assert!(profiles[1].alias_names.contains(&"agentstudio".to_string()));
        assert_eq!(profiles[2].collection_path_segments, vec!["osysit"]);
        assert_eq!(profiles[2].canonical_names, vec!["osysit"]);
    }

    #[test]
    fn archive_profile_completes_phrase_keyword_aliases() {
        let keywords = archive_keywords(&json!({
            "keywords": "Design Studio"
        }))
        .unwrap();
        let profile =
            derived_archive_profile(&keywords, Path::new("/tmp/archive"), &["codex".into()])
                .unwrap();

        assert_eq!(profile.profile_id, "design-studio");
        assert_eq!(profile.collection_path_segments, vec!["design-studio"]);
        assert_eq!(profile.canonical_names, vec!["Design Studio"]);
        assert_eq!(profile.alias_names, vec!["designstudio"]);

        let compact_candidate = json!({
            "title": "designstudio migration thread",
            "messages": []
        });
        let compact_match = profile_match(&compact_candidate, &profile).unwrap();
        assert_eq!(compact_match.matched_terms, vec!["designstudio"]);
        assert_eq!(compact_match.confidence, "medium");

        let duplicate_form_candidate = json!({
            "title": "Design Studio designstudio migration thread",
            "messages": []
        });
        let duplicate_form_match = profile_match(&duplicate_form_candidate, &profile).unwrap();
        assert_eq!(duplicate_form_match.confidence, "medium");

        let camel_keywords = archive_keywords(&json!({
            "keywords": "DesignStudio"
        }))
        .unwrap();
        let camel_profile = derived_archive_profile(
            &camel_keywords,
            Path::new("/tmp/archive"),
            &["codex".into()],
        )
        .unwrap();
        assert_eq!(camel_profile.profile_id, "designstudio");
        assert_eq!(camel_profile.alias_names, vec!["Design Studio"]);
        let spaced_candidate = json!({
            "title": "Design Studio migration thread",
            "messages": []
        });
        assert!(profile_match(&spaced_candidate, &camel_profile).is_some());
    }

    #[test]
    fn profile_matching_ignores_metadata_identity_terms() {
        let keywords = archive_keywords(&json!({
            "keywords": "Agent Studio"
        }))
        .unwrap();
        let profile =
            derived_archive_profile(&keywords, Path::new("/tmp/archive"), &["codex".into()])
                .unwrap();
        let candidate = json!({
            "title": "Unrelated Pact work",
            "nativeSessionId": "pact-session",
            "messages": [
                {"role": "metadata", "text": "base instructions mention Agent Studio"},
                {"role": "user", "text": "Continue unrelated Pact work"}
            ]
        });

        assert!(candidate_has_real_conversation(&candidate));
        assert!(profile_match(&candidate, &profile).is_none());
    }

    #[test]
    fn root_set_initializes_empty_user_root_and_persists_settings() {
        let state = temp_dir("root-state");
        let root = temp_dir("snapshot-root");
        fs::remove_dir_all(&root).unwrap();

        let result = root_set(&json!({
            "stateRoot": display_path(&state),
            "path": display_path(&root)
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert!(root.join(MARKER_FILE).exists());
        let get = root_get(&json!({"stateRoot": display_path(&state)})).unwrap();
        assert_eq!(get["snapshotRoot"], display_path(&root));
        assert_eq!(get["mode"], "user-controlled");
    }

    #[test]
    fn collect_creates_empty_collection_when_no_native_history_matches() {
        let state = temp_dir("empty-state");
        let home = temp_dir("empty-home");

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "missing topic"
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "empty");
        assert_eq!(result["selectedCount"], 0);
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        let collection = read_json_or_default(&collection_path, || json!({})).unwrap();
        assert_eq!(collection["state"], "empty");
        assert_eq!(collection["topicKey"], "missing-topic");
    }

    #[test]
    fn collect_materializes_matching_codex_jsonl_snapshot() {
        let state = temp_dir("collect-state");
        let home = temp_dir("collect-home");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            [
                r#"{"sessionId":"session-1","role":"user","content":"Investigate Codex Spark billing"}"#,
                r#"{"sessionId":"session-1","role":"assistant","content":"Billing answer"}"#,
                r#"{"sessionId":"session-2","role":"user","content":"Unrelated topic"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "codex spark"
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "materialized");
        assert_eq!(result["selectedCount"], 1);
        let written = result["written"].as_array().unwrap();
        let raw_path = PathBuf::from(written[0]["rawContentPath"].as_str().unwrap());
        let raw = fs::read_to_string(raw_path).unwrap();
        assert!(raw.contains("Investigate Codex Spark billing"));
        assert!(!raw.contains("Unrelated topic"));
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        let collection = read_json_or_default(&collection_path, || json!({})).unwrap();
        assert_eq!(collection["conversations"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn collect_scans_user_added_target_history_roots() {
        let state = temp_dir("manual-history-state");
        let home = temp_dir("manual-history-home");
        let manual_history = temp_dir("manual-history-root");
        fs::write(
            manual_history.join("manual-codex-history.jsonl"),
            r#"{"sessionId":"manual-session","role":"user","content":"Manual archive root topic"}"#,
        )
        .unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                TARGETS_COLLECTION,
                json!({
                    "items": [{
                        "target": "codex",
                        "manual": true,
                        "historyRoots": [display_path(&manual_history)]
                    }]
                }),
            )
            .unwrap();

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "manual archive root"
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "materialized");
        assert_eq!(result["selectedCount"], 1);
        assert_eq!(result["written"][0]["selection"]["mode"], "deterministic");
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        let collection = read_json_or_default(&collection_path, || json!({})).unwrap();
        assert!(
            collection["sources"]
                .as_array()
                .unwrap()
                .iter()
                .any(|source| {
                    source["scope"] == "manual-target-history-root"
                        && source["historyRoot"] == display_path(&manual_history)
                })
        );
        assert_eq!(
            collection["conversations"][0]["sourcePath"],
            display_path(&manual_history.join("manual-codex-history.jsonl"))
        );
    }

    #[test]
    fn archive_collect_derives_profile_scans_targets_and_writes_destination() {
        let state = temp_dir("keyword-archive-state");
        let home = temp_dir("keyword-archive-home");
        let destination = temp_dir("keyword-archive-destination");
        let manual_history = temp_dir("keyword-archive-history");
        fs::write(
            manual_history.join("manual-codex-history.jsonl"),
            [
                r#"{"sessionId":"pactium-session","role":"user","content":"Pactium archive keyword"}"#,
                r#"{"sessionId":"pact-session","role":"user","content":"Pact archive keyword"}"#,
                r#"{"sessionId":"agent-studio-session","role":"user","content":"agentstudio archive keyword"}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                TARGETS_COLLECTION,
                json!({
                    "items": [{
                        "target": "codex",
                        "manual": true,
                        "historyRoots": [display_path(&manual_history)]
                    }]
                }),
            )
            .unwrap();

        let result = archive_collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Pactium,Pact,Agent Studio",
            "path": display_path(&destination),
            "curation": "false",
            "archiveParallelism": 1
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "archived");
        assert_eq!(result["entry"], "keyword-archive");
        assert_eq!(result["keywordCount"], 3);
        assert_eq!(result["selectedCount"], 3);
        assert_eq!(result["documentCount"], 3);
        assert!(result.get("validation").is_none());
        assert_eq!(result["targetScan"]["includedAgents"][0], "codex");
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        assert!(collection_path.exists());
        let archives = result["archives"].as_array().unwrap();
        assert_eq!(archives[0]["keyword"], "Pactium");
        assert_eq!(archives[0]["folderName"], "pactium");
        assert_eq!(archives[1]["keyword"], "Pact");
        assert_eq!(archives[1]["folderName"], "pact");
        assert_eq!(archives[2]["keyword"], "Agent Studio");
        assert_eq!(archives[2]["folderName"], "agent-studio");
        assert!(destination.join("pactium").join(COLLECTION_JSON).exists());
        assert!(destination.join("pact").join(COLLECTION_JSON).exists());
        assert!(
            destination
                .join("agent-studio")
                .join(COLLECTION_JSON)
                .exists()
        );
        assert!(
            !destination
                .join("collections")
                .join("pactium")
                .join("pact")
                .exists()
        );
        assert!(PathBuf::from(archives[2]["documents"]["summary"].as_str().unwrap()).exists());
    }

    #[test]
    fn archive_target_scan_accepts_desktop_preflight_json() {
        let scan = json!({
            "ok": true,
            "source": "desktop-preflight",
            "candidates": [{
                "target": "codex",
                "label": "Codex",
                "status": "detected",
                "historyRoots": ["/tmp/codex-history"]
            }]
        });

        let result = archive_target_scan(&json!({
            "targetScanJson": scan.to_string()
        }))
        .unwrap();

        assert_eq!(result["source"], "desktop-preflight");
        assert_eq!(result["candidates"][0]["target"], "codex");
    }

    #[test]
    fn remote_history_relative_paths_cover_known_targets() {
        for target in [
            "antigravity",
            "claude-code",
            "code",
            "codex",
            "copilot",
            "cursor",
            "hermes",
            "kilo-code",
            "kimi",
            "kimi-code",
            "openclaw",
            "opencode",
            "pi",
        ] {
            assert!(
                !remote_history_relative_paths(target).is_empty(),
                "expected remote history paths for {}",
                target
            );
        }
    }

    #[test]
    fn remote_history_relative_paths_are_derived_from_registered_remote_roots() {
        let roots = json!([
            "lico-remote://docker/known-target-box/$HOME/.config/Code/User/workspaceStorage",
            "lico-remote://docker/known-target-box/$HOME/.config/Code/User/globalStorage",
            "lico-remote://docker/known-target-box/$HOME/.config/Code/User/workspaceStorage"
        ]);

        let paths = remote_history_relative_paths_from_value(Some(&roots));
        assert_eq!(
            paths,
            vec![
                ".config/Code/User/workspaceStorage".to_string(),
                ".config/Code/User/globalStorage".to_string()
            ]
        );
    }

    #[test]
    fn remote_history_target_uses_registered_paths_when_roots_are_absent() {
        let candidate = json!({
            "id": "codex:docker:known-target-box:/usr/local/bin/codex",
            "target": "codex",
            "label": "Codex",
            "location": "docker",
            "optionOverrides": {
                "execution-location": "docker",
                "remote-id": "known-target-box",
                "remote-name": "known-target-box",
                "remote-bin": "docker"
            }
        });

        let target = remote_history_target_from_candidate(&candidate, "codex").unwrap();
        assert_eq!(
            target.relative_paths,
            vec![
                ".codex/history.jsonl".to_string(),
                ".codex/session_index.jsonl".to_string(),
                ".codex/sessions".to_string(),
                ".codex/archived_sessions".to_string(),
                ".codex/memories".to_string()
            ]
        );
    }

    #[test]
    fn extract_tar_gz_materializes_codex_archive_fixture_with_private_boundary() {
        let fixture_home = temp_dir("remote-mirror-home");
        let archive_root = temp_dir("remote-mirror-archive");
        let codex_dir = fixture_home.join(".codex");
        fs::create_dir_all(&codex_dir).unwrap();
        fs::write(
            codex_dir.join("history.jsonl"),
            [
                r#"{"sessionId":"remote-codex-session","role":"user","content":"Mirror this Codex history"}"#,
                r#"{"sessionId":"remote-codex-session","role":"assistant","content":"Mirrored answer"}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let archive_path = archive_root.join("codex-history.tar.gz");
        let tar_status = Command::new("tar")
            .args(["-czf"])
            .arg(&archive_path)
            .args(["-C"])
            .arg(&fixture_home)
            .arg(".codex")
            .status()
            .unwrap();
        assert!(tar_status.success());
        let mirror_home = archive_root.join("mirror-home");
        ensure_private_dir(&mirror_home).unwrap();
        extract_tar_gz(&fs::read(&archive_path).unwrap(), &mirror_home).unwrap();
        harden_private_tree(&mirror_home).unwrap();

        let listed = conversations::conversation_list(&json!({
            "agent": "codex",
            "homeDir": display_path(&mirror_home)
        }))
        .unwrap();
        assert_eq!(listed["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(
            listed["sessions"][0]["nativeSessionId"],
            "remote-codex-session"
        );

        #[cfg(windows)]
        {
            let mirrored_history = mirror_home.join(".codex/history.jsonl");
            let output = Command::new("icacls")
                .arg(&mirrored_history)
                .output()
                .unwrap();
            let stdout = String::from_utf8_lossy(&output.stdout);
            assert!(output.status.success());
            assert!(stdout.contains("OWNER RIGHTS:(F)"));
        }
    }

    #[test]
    fn pactium_keyword_uses_strict_current_project_archive() {
        let state = temp_dir("pactium-strict-state");
        let home = temp_dir("pactium-strict-home");
        let destination = temp_dir("pactium-strict-destination");
        let manual_history = temp_dir("pactium-strict-history");
        fs::write(
            manual_history.join("manual-codex-history.jsonl"),
            [
                r#"{"sessionId":"pactium-session","role":"user","content":"Pactium archive keyword"}"#,
                r#"{"sessionId":"pact-session","role":"user","content":"Pact archive keyword"}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                TARGETS_COLLECTION,
                json!({
                    "items": [{
                        "target": "codex",
                        "manual": true,
                        "historyRoots": [display_path(&manual_history)]
                    }]
                }),
            )
            .unwrap();

        let result = archive_collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Pactium",
            "path": display_path(&destination),
            "curation": "false"
        }))
        .unwrap();

        assert_eq!(result["status"], "archived");
        assert_eq!(result["selectedCount"], 1);
        assert_eq!(
            PathBuf::from(result["collectionPath"].as_str().unwrap()),
            destination.join("pactium").join(COLLECTION_JSON)
        );
        let records =
            read_index_records(&destination.join("pactium").join(CONVERSATION_INDEX_JSONL))
                .unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0]["native_session_id"], "pactium-session");
    }

    #[test]
    fn archive_collect_materializes_snapshots_in_parallel() {
        let state = temp_dir("parallel-archive-state");
        let home = temp_dir("parallel-archive-home");
        let destination = temp_dir("parallel-archive-destination");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            [
                r#"{"sessionId":"parallel-one","role":"user","content":"Pact parallel archive first"}"#,
                r#"{"sessionId":"parallel-two","role":"user","content":"Pact parallel archive second"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let result = archive_collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Pact",
            "path": display_path(&destination),
            "curation": "false",
            "archiveParallelism": 2
        }))
        .unwrap();

        assert_eq!(result["status"], "archived");
        assert_eq!(result["selectedCount"], 2);
        let index_path = PathBuf::from(result["documents"]["conversationIndex"].as_str().unwrap());
        let records = read_index_records(&index_path).unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0]["archive_status"], "new");
        assert!(records.iter().any(|record| {
            record["native_session_id"] == "parallel-one"
                && PathBuf::from(record["snapshot_path"].as_str().unwrap()).exists()
        }));
        assert!(records.iter().any(|record| {
            record["native_session_id"] == "parallel-two"
                && PathBuf::from(record["snapshot_path"].as_str().unwrap()).exists()
        }));
    }

    #[test]
    fn codex_rollout_raw_export_filters_by_payload_session_id() {
        let dir = temp_dir("codex-rollout-export");
        let path = dir.join("rollout.jsonl");
        fs::write(
            &path,
            [
                r#"{"timestamp":"2026-06-03T10:00:00Z","type":"session_meta","payload":{"id":"session-one","cwd":"/tmp/one"}}"#,
                r#"{"timestamp":"2026-06-03T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first session text"}]}}"#,
                r#"{"timestamp":"2026-06-03T10:00:02Z","sessionId":"session-two","type":"session_meta","payload":{"id":"session-two","cwd":"/tmp/two"}}"#,
                r#"{"timestamp":"2026-06-03T10:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"second session text"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let raw = export_jsonl_source(&path, "session-two").unwrap();

        assert_eq!(
            raw.export_kind,
            "codex-rollout-jsonl-native-session-records"
        );
        assert!(raw.content.contains("second session text"));
        assert!(!raw.content.contains("session_meta"));
        assert!(!raw.content.contains("session-one"));
        assert!(!raw.content.contains("first session text"));
        assert!(raw.diagnostics.is_empty());
    }

    #[test]
    fn preserved_index_records_skip_excluded_dependency_sources() {
        let previous = vec![
            json!({
                "archive_key": "dependency",
                "source_path": "/tmp/project/node_modules/pkg/README.md",
                "archive_status": "unchanged"
            }),
            json!({
                "archive_key": "history",
                "source_path": "/tmp/history/session.jsonl",
                "archive_status": "unchanged"
            }),
        ];
        let current = BTreeSet::<String>::new();
        let mut index_records = Vec::<Value>::new();

        append_preserved_index_records(&previous, &current, &mut index_records);

        assert_eq!(index_records.len(), 1);
        assert_eq!(index_records[0]["archive_key"], "history");
        assert_eq!(index_records[0]["archive_status"], "preserved");
    }

    #[test]
    fn prune_removes_excluded_unindexed_snapshot_directories() {
        let collection_dir = temp_dir("prune-excluded-snapshots");
        let conversation_dir = collection_dir.join("conversations/hash");
        fs::create_dir_all(&conversation_dir).unwrap();
        atomic_write_json(
            &conversation_dir.join(SNAPSHOT_JSON),
            &json!({
                "snapshotId": "excluded",
                "sourcePath": "/tmp/project/node_modules/pkg/README.md"
            }),
        )
        .unwrap();

        prune_excluded_unindexed_snapshots(&collection_dir, &[]).unwrap();

        assert!(!conversation_dir.exists());
    }

    #[test]
    fn collect_exports_sqlite_rows_without_key_identity() {
        let state = temp_dir("sqlite-snapshot-state");
        let home = temp_dir("sqlite-snapshot-home");
        let opencode = home.join(".config/opencode");
        fs::create_dir_all(&opencode).unwrap();
        let db_path = opencode.join("history.db");
        {
            let connection = Connection::open(&db_path).unwrap();
            connection
                .execute("CREATE TABLE conversation_history (body TEXT)", [])
                .unwrap();
            connection
                .execute(
                    "INSERT INTO conversation_history (body) VALUES (?1)",
                    ["message: SQLite archive topic without stable row key"],
                )
                .unwrap();
        }

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "opencode",
            "topic": "sqlite archive topic"
        }))
        .unwrap();

        assert_eq!(result["status"], "materialized");
        let raw_path = PathBuf::from(result["written"][0]["rawContentPath"].as_str().unwrap());
        let raw = read_json_or_default(&raw_path, || json!({})).unwrap();
        assert_eq!(raw["rows"].as_array().unwrap().len(), 1);
        assert_eq!(raw["rows"][0]["table"], "conversation_history");
        let snapshot_path = PathBuf::from(result["written"][0]["snapshotPath"].as_str().unwrap());
        let snapshot = read_json_or_default(&snapshot_path, || json!({})).unwrap();
        assert_eq!(snapshot["rawExportKind"], "sqlite-native-session-records");
    }

    #[test]
    fn collect_refresh_preserves_previous_unseen_snapshots() {
        let state = temp_dir("preserve-state");
        let home = temp_dir("preserve-home");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"session-1","role":"user","content":"Archive topic first"}"#,
        )
        .unwrap();
        let first = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "archive topic"
        }))
        .unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"session-2","role":"user","content":"Archive topic second"}"#,
        )
        .unwrap();
        let second = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "archive topic"
        }))
        .unwrap();
        assert_eq!(first["selectedCount"], 1);
        assert_eq!(second["selectedCount"], 1);
        let collection_path = PathBuf::from(second["collectionPath"].as_str().unwrap());
        let collection = read_json_or_default(&collection_path, || json!({})).unwrap();
        assert_eq!(collection["conversations"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn bridge_ensure_writes_json_bridge_and_records_state() {
        let state = temp_dir("bridge-state");
        let config_dir = temp_dir("bridge-config");
        let config = config_dir.join("settings.json");
        fs::write(&config, "{}").unwrap();

        let result = bridge_ensure(&json!({
            "stateRoot": display_path(&state),
            "target": "codex",
            "configPath": display_path(&config)
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        let written: Value = serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
        assert!(written.get(BRIDGE_CONFIG_KEY).is_some());
        let store = ClientStateStore::new(state).unwrap();
        let bridges = store.read_collection(BRIDGES_COLLECTION).unwrap();
        assert_eq!(bridges["items"][0]["target"], "codex");
        assert_eq!(bridges["items"][0]["status"], "verified");
    }

    #[test]
    fn structured_curation_result_can_select_non_matching_candidate() {
        let state = temp_dir("curated-state");
        let home = temp_dir("curated-home");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"session-1","role":"user","content":"A curator-only conversation"}"#,
        )
        .unwrap();
        let listed = conversations::conversation_list(
            &json!({"agent": "codex", "homeDir": display_path(&home)}),
        )
        .unwrap();
        let candidate_id = listed["sessions"][0]["id"].as_str().unwrap().to_string();

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "different topic",
            "curationResultJson": serde_json::to_string(&json!({
                "selectedCandidateIds": [candidate_id],
                "reasonsByCandidateId": {
                    candidate_id: "curator linked this conversation to the topic"
                }
            })).unwrap()
        }))
        .unwrap();

        assert_eq!(result["status"], "materialized");
        assert_eq!(result["selectedCount"], 1);
        assert_eq!(result["curation"]["status"], "structured_result_provided");
    }

    #[test]
    fn preferred_curator_runtime_output_can_select_non_matching_candidate() {
        let state = temp_dir("preferred-curator-state");
        let home = temp_dir("preferred-curator-home");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        let history_path = codex.join("history.jsonl");
        fs::write(
            &history_path,
            r#"{"sessionId":"session-curated","role":"user","content":"Semantic archive candidate"}"#,
        )
        .unwrap();
        let listed = conversations::conversation_list(
            &json!({"agent": "codex", "homeDir": display_path(&home)}),
        )
        .unwrap();
        let candidate_id = listed["sessions"][0]["id"].as_str().unwrap().to_string();
        let curation_json = serde_json::to_string(&json!({
            "selectedCandidateIds": [candidate_id],
            "reasonsByCandidateId": {
                candidate_id: "runtime curator selected this semantic match"
            }
        }))
        .unwrap();
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("fake_codex_app_server.rs");
        let executable = home.join(format!(
            "fake-codex-curator{}",
            std::env::consts::EXE_SUFFIX
        ));
        let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
        let compile = TestCommand::new(rustc)
            .arg("--edition=2024")
            .arg(&fixture)
            .arg("-o")
            .arg(&executable)
            .status()
            .expect("fake Codex curator fixture should compile");
        assert!(compile.success());
        let mut result_path = executable.clone();
        result_path.set_extension("result.json");
        fs::write(result_path, &curation_json).unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                BRIDGES_COLLECTION,
                json!({
                    "items": [{
                        "target": "codex",
                        "bridgeId": "snapshot-curation-codex",
                        "status": "verified"
                    }]
                }),
            )
            .unwrap();
        curator_set(&json!({
            "stateRoot": display_path(&state),
            "target": "codex"
        }))
        .unwrap();

        let result = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "different topic",
            "binary": display_path(&executable)
        }))
        .unwrap();

        assert_eq!(result["status"], "materialized");
        assert_eq!(result["selectedCount"], 1);
        assert_eq!(
            result["curation"]["status"],
            "runtime_output_structured_result"
        );
        assert_eq!(result["written"][0]["selection"]["mode"], "curated");
    }

    #[test]
    fn curation_session_tools_are_session_scoped_and_budgeted() {
        let state = temp_dir("curation-session-state");
        let home = temp_dir("curation-session-home");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"session-1","role":"user","content":"Budgeted curation candidate"}"#,
        )
        .unwrap();

        assert!(curation_candidates_list(&json!({"stateRoot": display_path(&state)})).is_err());
        let started = curation_start(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "different topic",
            "readBudget": "1"
        }))
        .unwrap();
        assert_eq!(started["status"], "started");
        let session_id = started["curationSessionId"].as_str().unwrap().to_string();
        let candidate_id = started["candidateBriefs"][0]["candidateId"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(started["candidateBriefs"][0].get("messages").is_none());

        let listed = curation_candidates_list(&json!({
            "stateRoot": display_path(&state),
            "curationSessionId": session_id
        }))
        .unwrap();
        assert_eq!(listed["candidateBriefs"].as_array().unwrap().len(), 1);

        let expanded = curation_candidate_expand(&json!({
            "stateRoot": display_path(&state),
            "curationSessionId": session_id,
            "candidateId": candidate_id
        }))
        .unwrap();
        assert_eq!(expanded["status"], "expanded");
        assert_eq!(expanded["remainingExpansions"], 0);
        assert!(expanded["candidate"]["messages"].is_array());

        let exhausted = curation_candidate_expand(&json!({
            "stateRoot": display_path(&state),
            "curationSessionId": session_id,
            "candidateId": candidate_id
        }))
        .unwrap();
        assert_eq!(exhausted["status"], "read_budget_exhausted");

        let submitted = curation_submit_result(&json!({
            "stateRoot": display_path(&state),
            "curationSessionId": session_id,
            "curationResultJson": serde_json::to_string(&json!({
                "selectedCandidateIds": [candidate_id],
                "reasonsByCandidateId": {
                    candidate_id: "curator selected through session"
                }
            })).unwrap()
        }))
        .unwrap();
        assert_eq!(submitted["status"], "submitted");

        let collected = collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "topic": "different topic",
            "curationSessionId": session_id
        }))
        .unwrap();
        assert_eq!(collected["status"], "materialized");
        assert_eq!(collected["selectedCount"], 1);
        assert_eq!(collected["curation"]["status"], "session_result_submitted");
    }

    #[test]
    fn archive_profile_import_list_and_get_round_trip() {
        let state = temp_dir("archive-profile-state");
        let archive_root = temp_dir("archive-profile-root");

        let imported = profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileJson": serde_json::to_string(&json!({
                "profileId": "licolite",
                "displayName": "LicoLite",
                "archiveRoot": display_path(&archive_root),
                "canonicalNames": ["LicoLite"],
                "aliasNames": ["LicoLite-Archive-Alias"],
                "projectPaths": ["/repo/licolite"],
                "expectedAgents": ["codex"],
                "expectedSources": ["codex"]
            })).unwrap()
        }))
        .unwrap();
        assert_eq!(imported["status"], "imported");
        assert_eq!(imported["profile"]["profileId"], "licolite");

        let list = profiles_list(&json!({"stateRoot": display_path(&state)})).unwrap();
        assert_eq!(list["profiles"].as_array().unwrap().len(), 1);
        let get = profile_get(&json!({
            "stateRoot": display_path(&state),
            "profile": "licolite"
        }))
        .unwrap();
        assert_eq!(get["profile"]["displayName"], "LicoLite");
        assert_eq!(get["profile"]["expectedAgents"][0], "codex");
    }

    #[test]
    fn archive_run_materializes_profile_index_summary_and_report() {
        let state = temp_dir("archive-run-state");
        let home = temp_dir("archive-run-home");
        let archive_root = temp_dir("archive-run-root");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"licolite-1","role":"user","content":"Work on LicoLite at /repo/licolite"}"#,
        )
        .unwrap();
        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite",
            "displayName": "LicoLite",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "projectPaths": "/repo/licolite",
            "expectedAgents": "codex"
        }))
        .unwrap();

        let result = archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite",
            "trigger": "agent"
        }))
        .unwrap();

        assert_eq!(result["status"], "materialized");
        assert_eq!(result["mode"], "conversation-archive");
        assert_eq!(result["selectedCount"], 1);
        assert_eq!(result["validation"]["healthStatus"], "ok");
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        let collection = read_json_or_default(&collection_path, || json!({})).unwrap();
        assert_eq!(collection["kind"], "native-conversation-archive");
        let index_path = archive_root
            .join("collections")
            .join("licolite")
            .join(CONVERSATION_INDEX_JSONL);
        let index = read_index_records(&index_path).unwrap();
        assert_eq!(index.len(), 1);
        assert_eq!(index[0]["confidence"], "high");
        assert_eq!(index[0]["archive_status"], "new");
        let semantic_json_path = PathBuf::from(
            index[0]["semantic_document_path"]
                .as_str()
                .expect("semantic JSON path"),
        );
        let semantic_markdown_path = PathBuf::from(
            index[0]["semantic_markdown_path"]
                .as_str()
                .expect("semantic Markdown path"),
        );
        assert!(semantic_json_path.exists());
        assert!(semantic_markdown_path.exists());
        assert!(
            !index[0]["semantic_content_hash"]
                .as_str()
                .unwrap_or_default()
                .is_empty()
        );
        let semantic: Value =
            serde_json::from_str(&fs::read_to_string(&semantic_json_path).unwrap()).unwrap();
        crate::domain::conversation_semantic::validate_semantic_conversation(&semantic).unwrap();
        for layer in ["thread", "execution", "artifacts", "audit", "raw"] {
            assert!(
                semantic.get(layer).is_some(),
                "missing semantic {layer} layer"
            );
        }
        assert!(
            archive_root
                .join("collections/licolite/summary.md")
                .exists()
        );
        let index_markdown_path = archive_root
            .join("collections")
            .join("licolite")
            .join(CONVERSATION_INDEX_MD);
        assert!(index_markdown_path.exists());
        assert!(
            fs::read_to_string(index_markdown_path)
                .unwrap()
                .contains(SEMANTIC_MD)
        );
        assert!(
            archive_root
                .join("collections/licolite/sources.json")
                .exists()
        );
        assert!(
            archive_root
                .join("collections/licolite/matches.jsonl")
                .exists()
        );
        assert!(
            archive_root
                .join("collections/licolite/validation.json")
                .exists()
        );

        let report = archive_report(&json!({
            "stateRoot": display_path(&state),
            "profile": "licolite"
        }))
        .unwrap();
        assert_eq!(report["indexCount"], 1);
        assert_eq!(report["validation"]["healthStatus"], "ok");
    }

    #[test]
    fn archive_validation_detects_semantic_missing_stale_duplicate_and_metadata_only_records() {
        let state = temp_dir("archive-semantic-validation-state");
        let home = temp_dir("archive-semantic-validation-home");
        let archive_root = temp_dir("archive-semantic-validation-root");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"semantic-validation-1","role":"user","content":"LicoLite semantic validation"}"#,
        )
        .unwrap();
        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite-semantic-validation",
            "displayName": "LicoLite Semantic Validation",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex"
        }))
        .unwrap();
        archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-semantic-validation"
        }))
        .unwrap();

        let collection_dir = archive_root
            .join("collections")
            .join("licolite-semantic-validation");
        let index_path = collection_dir.join(CONVERSATION_INDEX_JSONL);
        let mut records = read_index_records(&index_path).unwrap();
        assert_eq!(records.len(), 1);
        let original = records[0].clone();
        let profile = parse_archive_profile(&json!({
            "profileId": "licolite-semantic-validation",
            "displayName": "LicoLite Semantic Validation",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex"
        }))
        .unwrap();
        let semantic_path = PathBuf::from(
            original["semantic_document_path"]
                .as_str()
                .expect("semantic document path"),
        );
        let semantic_markdown_path = PathBuf::from(
            original["semantic_markdown_path"]
                .as_str()
                .expect("semantic markdown path"),
        );
        let semantic_original = fs::read_to_string(&semantic_path).unwrap();
        let semantic_markdown_original = fs::read_to_string(&semantic_markdown_path).unwrap();

        fs::remove_file(&semantic_markdown_path).unwrap();
        let missing = validate_archive_collection(&collection_dir, &records, &profile).unwrap();
        assert!(missing["issues"].as_array().unwrap().iter().any(|issue| {
            issue["type"] == "missing_semantic_document"
                && issue["field"] == "semantic_markdown_path"
        }));
        fs::write(&semantic_markdown_path, semantic_markdown_original).unwrap();

        fs::write(&semantic_path, "{}\n").unwrap();
        let stale = validate_archive_collection(&collection_dir, &records, &profile).unwrap();
        assert!(
            stale["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| issue["type"] == "stale_semantic_hash")
        );
        fs::write(&semantic_path, &semantic_original).unwrap();

        let duplicate = validate_archive_collection(
            &collection_dir,
            &[original.clone(), original.clone()],
            &profile,
        )
        .unwrap();
        assert!(
            duplicate["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| issue["type"] == "duplicate_archive_key")
        );

        let mut metadata_semantic: Value = serde_json::from_str(&semantic_original).unwrap();
        metadata_semantic["thread"] = json!([]);
        metadata_semantic["execution"] = json!([]);
        let metadata_json = serde_json::to_string_pretty(&metadata_semantic).unwrap();
        fs::write(&semantic_path, format!("{metadata_json}\n")).unwrap();
        records[0]["semantic_content_hash"] = json!(hash_text(&metadata_json));
        records[0]["match_reason"] = json!("metadata-only candidate");
        let metadata_only =
            validate_archive_collection(&collection_dir, &records, &profile).unwrap();
        assert!(
            metadata_only["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| {
                    issue["type"] == "metadata_only_false_positive"
                        && issue["severity"] == "warning"
                })
        );

        fs::write(&semantic_path, semantic_original).unwrap();
        let raw_path = PathBuf::from(
            original["raw_content_path"]
                .as_str()
                .expect("raw content path"),
        );
        fs::write(raw_path, b"tampered\n").unwrap();
        let raw_stale =
            validate_archive_collection(&collection_dir, &[original], &profile).unwrap();
        assert!(
            raw_stale["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| { issue["type"] == "raw_content_fingerprint_mismatch" })
        );
    }

    #[test]
    fn archive_mode_streams_jsonl_that_browse_mode_skips_as_large() {
        let state = temp_dir("archive-large-state");
        let home = temp_dir("archive-large-home");
        let archive_root = temp_dir("archive-large-root");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        let large_text = "x".repeat((32 * 1024 * 1024) + 2048);
        fs::write(
            codex.join("history.jsonl"),
            format!(
                "{{\"sessionId\":\"large-1\",\"role\":\"user\",\"content\":\"LicoLite {}\"}}\n",
                large_text
            ),
        )
        .unwrap();

        let browse = conversations::conversation_list(
            &json!({"agent": "codex", "homeDir": display_path(&home)}),
        )
        .unwrap();
        assert_eq!(browse["sessions"].as_array().unwrap().len(), 0);
        assert_eq!(browse["sources"]["skipped"][0]["reason"], "file_too_large");

        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite-large",
            "displayName": "LicoLite Large",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex"
        }))
        .unwrap();
        let archived = archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-large"
        }))
        .unwrap();
        assert_eq!(archived["selectedCount"], 1);
        assert_eq!(archived["validation"]["healthStatus"], "ok");
    }

    #[test]
    fn archive_run_marks_incremental_statuses_and_verify_missing_files() {
        let state = temp_dir("archive-incremental-state");
        let home = temp_dir("archive-incremental-home");
        let archive_root = temp_dir("archive-incremental-root");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        let history = codex.join("history.jsonl");
        fs::write(
            &history,
            r#"{"sessionId":"inc-1","role":"user","content":"LicoLite first"}"#,
        )
        .unwrap();
        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite-inc",
            "displayName": "LicoLite Incremental",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex"
        }))
        .unwrap();

        archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-inc"
        }))
        .unwrap();
        archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-inc"
        }))
        .unwrap();
        let index_path = archive_root
            .join("collections")
            .join("licolite-inc")
            .join(CONVERSATION_INDEX_JSONL);
        let index = read_index_records(&index_path).unwrap();
        assert_eq!(index[0]["archive_status"], "unchanged");

        fs::write(
            &history,
            r#"{"sessionId":"inc-1","role":"user","content":"LicoLite changed"}"#,
        )
        .unwrap();
        archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-inc"
        }))
        .unwrap();
        let index = read_index_records(&index_path).unwrap();
        assert_eq!(index[0]["archive_status"], "updated");
        let raw_path = PathBuf::from(index[0]["raw_content_path"].as_str().unwrap());
        fs::remove_file(raw_path).unwrap();
        let verify = archive_verify(&json!({
            "stateRoot": display_path(&state),
            "profile": "licolite-inc"
        }))
        .unwrap();
        assert_eq!(verify["validation"]["healthStatus"], "failed");
        assert_eq!(verify["validation"]["errorCount"], 1);
    }

    #[test]
    fn archive_verify_recomputes_raw_content_fingerprint() {
        let state = temp_dir("archive-fingerprint-state");
        let home = temp_dir("archive-fingerprint-home");
        let archive_root = temp_dir("archive-fingerprint-root");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"fingerprint-1","role":"user","content":"LicoLite fingerprint"}"#,
        )
        .unwrap();
        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite-fingerprint",
            "displayName": "LicoLite Fingerprint",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex"
        }))
        .unwrap();

        archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-fingerprint"
        }))
        .unwrap();
        let index_path = archive_root
            .join("collections")
            .join("licolite-fingerprint")
            .join(CONVERSATION_INDEX_JSONL);
        let index = read_index_records(&index_path).unwrap();
        let raw_path = PathBuf::from(index[0]["raw_content_path"].as_str().unwrap());
        fs::write(&raw_path, b"{\"tampered\":true}\n").unwrap();

        let verify = archive_verify(&json!({
            "stateRoot": display_path(&state),
            "profile": "licolite-fingerprint"
        }))
        .unwrap();
        assert_eq!(verify["validation"]["healthStatus"], "failed");
        assert!(
            verify["validation"]["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| issue["type"] == "raw_content_fingerprint_mismatch")
        );
    }

    #[test]
    fn archive_verify_collection_path_recomputes_hashes_for_keyword_archives() {
        let state = temp_dir("keyword-verify-state");
        let home = temp_dir("keyword-verify-home");
        let destination = temp_dir("keyword-verify-destination");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"keyword-verify-1","role":"user","content":"LicoLite keyword verify"}"#,
        )
        .unwrap();

        let result = archive_collect(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "LicoLite",
            "path": display_path(&destination),
            "curation": "false"
        }))
        .unwrap();
        let collection_path = PathBuf::from(result["collectionPath"].as_str().unwrap());
        let index = read_index_records(
            &collection_path
                .parent()
                .unwrap()
                .join(CONVERSATION_INDEX_JSONL),
        )
        .unwrap();
        let raw_path = PathBuf::from(index[0]["raw_content_path"].as_str().unwrap());
        fs::write(&raw_path, b"{\"copiedButCorrupt\":true}\n").unwrap();

        let verify = archive_verify(&json!({
            "collectionPath": display_path(&collection_path)
        }))
        .unwrap();
        assert_eq!(verify["validation"]["healthStatus"], "failed");
        assert!(
            verify["validation"]["issues"]
                .as_array()
                .unwrap()
                .iter()
                .any(|issue| issue["type"] == "raw_content_fingerprint_mismatch")
        );
    }

    #[test]
    fn archive_validation_reports_baseline_coverage() {
        let state = temp_dir("archive-baseline-state");
        let home = temp_dir("archive-baseline-home");
        let archive_root = temp_dir("archive-baseline-root");
        let baseline = temp_dir("archive-baseline-index").join("conversation-index.jsonl");
        write_jsonl(
            &baseline,
            &[
                json!({"archive_key": "a", "raw_content_bytes": 10}),
                json!({"archive_key": "b", "raw_content_bytes": 10}),
            ],
        )
        .unwrap();
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(
            codex.join("history.jsonl"),
            r#"{"sessionId":"baseline-1","role":"user","content":"LicoLite baseline"}"#,
        )
        .unwrap();
        profile_import(&json!({
            "stateRoot": display_path(&state),
            "profileId": "licolite-baseline",
            "displayName": "LicoLite Baseline",
            "archiveRoot": display_path(&archive_root),
            "canonicalNames": "LicoLite",
            "expectedAgents": "codex",
            "baselineIndexPath": display_path(&baseline)
        }))
        .unwrap();

        let result = archive_run(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "profile": "licolite-baseline"
        }))
        .unwrap();

        assert_eq!(result["validation"]["baseline"]["status"], "compared");
        assert_eq!(result["validation"]["baseline"]["baselineCount"], 2);
        assert_eq!(result["validation"]["baseline"]["currentCount"], 1);
    }

    fn temp_dir(name: &str) -> PathBuf {
        let counter = TEMP_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = env::temp_dir().join(format!(
            "lico-conversation-snapshots-{}-{}-{}-{}",
            name,
            std::process::id(),
            timestamp_stamp(),
            counter
        ));
        fs::create_dir_all(&dir).unwrap();
        // macOS exposes the system temporary directory through a stable
        // symlink alias. Archive extraction deliberately rejects symlinked
        // destination ancestors, so tests exercise the real no-follow path.
        dir.canonicalize().unwrap()
    }
}
