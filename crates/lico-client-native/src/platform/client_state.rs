use crate::platform::file_security::{
    append_private_line, atomic_write_private_text, ensure_private_dir,
};
use crate::platform::paths::portable_data_dir;
use anyhow::{Result, anyhow};
use regex::Regex;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const STATE_SCHEMA_VERSION: &str = "v0.0.1:schema:definition-1";
const CLIENT_STATE_DIR: &str = "lico-client";
const ACTIVITY_FILE: &str = "activity.jsonl";
const SNAPSHOT_DIR: &str = "snapshots";
const REDACTED_SECRET: &str = "<redacted-secret>";
const COLLECTIONS: &[&str] = &[
    "settings",
    "targets",
    "pairings",
    "skills",
    "pins",
    "identities",
    "snapshot-bridges",
    "conversation-archive-profiles",
    "agent-usage-reports",
    "proxy-bridge",
];

#[derive(Clone, Debug)]
pub struct ClientStateStore {
    root: PathBuf,
}

#[derive(Clone, Debug)]
pub struct ActivityLog {
    path: PathBuf,
}

#[derive(Clone, Debug)]
pub struct SnapshotStore {
    root: PathBuf,
}

#[derive(Clone, Debug)]
pub struct SnapshotRecord {
    pub snapshot_id: String,
    pub snapshot_path: PathBuf,
    pub source_path: PathBuf,
    pub existed: bool,
    pub content: String,
}

impl ClientStateStore {
    pub fn portable() -> Result<Self> {
        Self::new(portable_data_dir()?.join(CLIENT_STATE_DIR))
    }

    pub fn new(root: PathBuf) -> Result<Self> {
        ensure_private_dir(&root)?;
        ensure_private_dir(&root.join(SNAPSHOT_DIR))?;
        ensure_private_dir(&root.join("activity"))?;
        let store = Self { root };
        store.ensure_collections()?;
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn collection_path(&self, collection: &str) -> Result<PathBuf> {
        validate_collection(collection)?;
        Ok(self.root.join(format!("{}.json", collection)))
    }

    pub fn read_collection(&self, collection: &str) -> Result<Value> {
        let path = self.collection_path(collection)?;
        read_json_or_default(&path, || empty_collection(collection))
    }

    pub fn write_collection(&self, collection: &str, value: Value) -> Result<Value> {
        let path = self.collection_path(collection)?;
        let document = normalize_collection(collection, value);
        atomic_write_json(&path, &document)?;
        Ok(document)
    }

    pub fn activity_log(&self) -> ActivityLog {
        ActivityLog {
            path: self.root.join("activity").join(ACTIVITY_FILE),
        }
    }

    pub fn snapshot_store(&self) -> SnapshotStore {
        SnapshotStore {
            root: self.root.join(SNAPSHOT_DIR),
        }
    }

    fn ensure_collections(&self) -> Result<()> {
        for collection in COLLECTIONS {
            let path = self.collection_path(collection)?;
            if !path.exists() {
                atomic_write_json(&path, &empty_collection(collection))?;
            }
        }
        Ok(())
    }
}

impl ActivityLog {
    pub fn portable() -> Result<Self> {
        Ok(ClientStateStore::portable()?.activity_log())
    }

    pub fn append(&self, event_type: &str, payload: Value) -> Result<Value> {
        let event = json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "eventId": format!("activity-{}", timestamp()),
            "type": event_type,
            "target": payload.get("target").and_then(Value::as_str).unwrap_or(""),
            "createdAt": timestamp(),
            "payload": payload,
        });
        append_private_line(&self.path, &serde_json::to_string(&event)?)?;
        Ok(event)
    }

    pub fn list(&self, filter: &Value) -> Result<Value> {
        let mut events = Vec::<Value>::new();
        if self.path.exists() {
            let file = fs::File::open(&self.path)?;
            for line in BufReader::new(file).lines() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let event: Value = serde_json::from_str(&line)?;
                if matches_activity_filter(&event, filter) {
                    events.push(event);
                }
            }
        }
        if let Some(limit) = filter.get("limit").and_then(Value::as_u64) {
            let limit = limit as usize;
            if events.len() > limit {
                events = events[events.len() - limit..].to_vec();
            }
        }
        Ok(json!({
            "ok": true,
            "schemaVersion": STATE_SCHEMA_VERSION,
            "path": display_path(self.path.clone()),
            "events": events
        }))
    }
}

impl SnapshotStore {
    pub fn portable() -> Result<Self> {
        Ok(ClientStateStore::portable()?.snapshot_store())
    }

    pub fn capture(
        &self,
        target: &str,
        source_path: &Path,
        metadata: Value,
    ) -> Result<SnapshotRecord> {
        fs::create_dir_all(&self.root)?;
        let existed = source_path.exists();
        let content = fs::read_to_string(source_path).unwrap_or_default();
        let (snapshot_content, redaction) = redact_snapshot_content(&content);
        let snapshot_id = format!("snapshot-{}-{}", sanitize_id(target), timestamp());
        let snapshot_path = self.root.join(format!("{}.json", snapshot_id));
        let record = json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "snapshotId": snapshot_id,
            "target": target,
            "sourcePath": display_path(source_path.to_path_buf()),
            "capturedAt": timestamp(),
            "existed": existed,
            "size": content.len(),
            "hash": hash_text(&content),
            "content": snapshot_content,
            "redaction": redaction,
            "metadata": metadata,
        });
        atomic_write_json(&snapshot_path, &record)?;
        Ok(SnapshotRecord {
            snapshot_id,
            snapshot_path,
            source_path: source_path.to_path_buf(),
            existed,
            content: snapshot_content,
        })
    }

    pub fn list(&self, filter: &Value) -> Result<Value> {
        let mut snapshots = Vec::<Value>::new();
        if self.root.exists() {
            for entry in fs::read_dir(&self.root)? {
                let entry = entry?;
                if entry.path().extension().and_then(|item| item.to_str()) != Some("json") {
                    continue;
                }
                let snapshot = read_json_or_default(&entry.path(), || json!({}))?;
                if matches_snapshot_filter(&snapshot, filter) {
                    snapshots.push(snapshot_summary(&snapshot, entry.path()));
                }
            }
        }
        snapshots.sort_by(|left, right| {
            left.get("capturedAt")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .cmp(
                    right
                        .get("capturedAt")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                )
        });
        Ok(json!({
            "ok": true,
            "schemaVersion": STATE_SCHEMA_VERSION,
            "path": display_path(self.root.clone()),
            "snapshots": snapshots
        }))
    }

    pub fn restore(&self, snapshot_id: &str) -> Result<Value> {
        let snapshot_path = self.snapshot_path(snapshot_id);
        let snapshot = read_json_or_default(&snapshot_path, || json!({}))?;
        let source_path = snapshot
            .get("sourcePath")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("snapshot is missing sourcePath"))?;
        let existed = snapshot
            .get("existed")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let content = snapshot
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let redaction_applied = snapshot
            .get("redaction")
            .and_then(|item| item.get("applied"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let pre_restore = self.capture(
            snapshot
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or("restore"),
            &source_path,
            json!({
                "reason": "pre-restore",
                "restoringSnapshotId": snapshot_id
            }),
        )?;
        if existed {
            atomic_write_text(&source_path, content)?;
        } else if source_path.exists() {
            fs::remove_file(&source_path)?;
        }
        Ok(json!({
            "ok": true,
            "status": "restored",
            "snapshotId": snapshot_id,
            "snapshotPath": display_path(snapshot_path),
            "sourcePath": display_path(source_path),
            "preRestoreSnapshotId": pre_restore.snapshot_id,
            "preRestoreSnapshotPath": display_path(pre_restore.snapshot_path),
            "redactionApplied": redaction_applied
        }))
    }

    fn snapshot_path(&self, snapshot_id: &str) -> PathBuf {
        self.root.join(format!("{}.json", snapshot_id))
    }
}

pub fn state_get(collection: &str) -> Result<Value> {
    let store = ClientStateStore::portable()?;
    Ok(json!({
        "ok": true,
        "collection": collection,
        "document": store.read_collection(collection)?
    }))
}

pub fn state_set(collection: &str, value: Value) -> Result<Value> {
    let store = ClientStateStore::portable()?;
    let document = store.write_collection(collection, value)?;
    let activity = store.activity_log().append(
        "state.collection.saved",
        json!({
            "collection": collection,
            "target": collection
        }),
    )?;
    Ok(json!({
        "ok": true,
        "collection": collection,
        "document": document,
        "activity": activity
    }))
}

pub fn activity_list(params: &Value) -> Result<Value> {
    ActivityLog::portable()?.list(params)
}

pub fn snapshots_list(params: &Value) -> Result<Value> {
    SnapshotStore::portable()?.list(params)
}

pub fn snapshots_restore(snapshot_id: &str) -> Result<Value> {
    let store = ClientStateStore::portable()?;
    let result = store.snapshot_store().restore(snapshot_id)?;
    let activity = store.activity_log().append(
        "snapshot.restored",
        json!({
            "target": result.get("sourcePath").and_then(Value::as_str).unwrap_or(""),
            "snapshotId": snapshot_id
        }),
    )?;
    Ok(json!({
        "ok": true,
        "restore": result,
        "activity": activity
    }))
}

fn validate_collection(collection: &str) -> Result<()> {
    if COLLECTIONS.contains(&collection) {
        Ok(())
    } else {
        Err(anyhow!(
            "unsupported client state collection: {}",
            collection
        ))
    }
}

fn empty_collection(collection: &str) -> Value {
    json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "collection": collection,
        "items": []
    })
}

fn normalize_collection(collection: &str, value: Value) -> Value {
    if value.is_object() {
        let mut object = value.as_object().cloned().unwrap_or_default();
        object
            .entry("schemaVersion".to_string())
            .or_insert_with(|| json!(STATE_SCHEMA_VERSION));
        object
            .entry("collection".to_string())
            .or_insert_with(|| json!(collection));
        Value::Object(object)
    } else {
        json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "collection": collection,
            "items": value
        })
    }
}

fn matches_activity_filter(event: &Value, filter: &Value) -> bool {
    let type_matches = filter
        .get("type")
        .and_then(Value::as_str)
        .map(|expected| event.get("type").and_then(Value::as_str) == Some(expected))
        .unwrap_or(true);
    let target_matches = filter
        .get("target")
        .and_then(Value::as_str)
        .map(|expected| event.get("target").and_then(Value::as_str) == Some(expected))
        .unwrap_or(true);
    type_matches && target_matches
}

fn matches_snapshot_filter(snapshot: &Value, filter: &Value) -> bool {
    filter
        .get("target")
        .and_then(Value::as_str)
        .map(|expected| snapshot.get("target").and_then(Value::as_str) == Some(expected))
        .unwrap_or(true)
}

fn snapshot_summary(snapshot: &Value, path: PathBuf) -> Value {
    json!({
        "schemaVersion": snapshot.get("schemaVersion").cloned().unwrap_or_else(|| json!(STATE_SCHEMA_VERSION)),
        "snapshotId": snapshot.get("snapshotId").cloned().unwrap_or_else(|| json!("")),
        "target": snapshot.get("target").cloned().unwrap_or_else(|| json!("")),
        "sourcePath": snapshot.get("sourcePath").cloned().unwrap_or_else(|| json!("")),
        "capturedAt": snapshot.get("capturedAt").cloned().unwrap_or_else(|| json!("")),
        "existed": snapshot.get("existed").cloned().unwrap_or_else(|| json!(false)),
        "size": snapshot.get("size").cloned().unwrap_or_else(|| json!(0)),
        "hash": snapshot.get("hash").cloned().unwrap_or_else(|| json!("")),
        "redaction": snapshot.get("redaction").cloned().unwrap_or_else(|| json!({
            "policy": "known-credential-fields",
            "applied": false,
            "paths": []
        })),
        "snapshotPath": display_path(path)
    })
}

fn redact_snapshot_content(content: &str) -> (String, Value) {
    let mut redacted_paths = Vec::<String>::new();
    if let Ok(mut parsed) = serde_json::from_str::<Value>(content) {
        redact_json_value(&mut parsed, "$", &mut redacted_paths);
        if redacted_paths.is_empty() {
            return (content.to_string(), redaction_metadata(redacted_paths));
        }
        let redacted =
            serde_json::to_string_pretty(&parsed).unwrap_or_else(|_| content.to_string());
        return (redacted, redaction_metadata(redacted_paths));
    }

    let redacted = redact_text_content(content, &mut redacted_paths);
    (redacted, redaction_metadata(redacted_paths))
}

fn redaction_metadata(paths: Vec<String>) -> Value {
    json!({
        "policy": "known-credential-fields",
        "applied": !paths.is_empty(),
        "paths": paths
    })
}

fn redact_json_value(value: &mut Value, path: &str, redacted_paths: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                let child_path = format_json_path(path, key);
                if is_sensitive_snapshot_key(key) {
                    if !matches!(child, Value::Null) {
                        *child = Value::String(REDACTED_SECRET.to_string());
                        redacted_paths.push(child_path);
                    }
                } else {
                    redact_json_value(child, &child_path, redacted_paths);
                }
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter_mut().enumerate() {
                redact_json_value(child, &format!("{path}[{index}]"), redacted_paths);
            }
        }
        Value::String(text) => {
            let redacted = redact_sensitive_text_value(text);
            if redacted != *text {
                *text = redacted;
                redacted_paths.push(path.to_string());
            }
        }
        _ => {}
    }
}

fn format_json_path(base: &str, key: &str) -> String {
    if key
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    {
        format!("{base}.{key}")
    } else {
        format!(
            "{base}[{}]",
            serde_json::to_string(key).unwrap_or_else(|_| "\"<key>\"".to_string())
        )
    }
}

fn is_sensitive_snapshot_key(key: &str) -> bool {
    let normalized = normalize_key(key);
    if matches!(
        normalized.as_str(),
        "secretref" | "credentialref" | "credentialid" | "keyid"
    ) {
        return false;
    }
    normalized.contains("token")
        || normalized.contains("apikey")
        || normalized.contains("password")
        || normalized.contains("secret")
        || normalized.contains("authorization")
        || normalized.contains("authheader")
        || normalized.contains("privatekey")
        || normalized.contains("clientsecret")
        || normalized.contains("csrf")
}

fn normalize_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn redact_text_content(content: &str, redacted_paths: &mut Vec<String>) -> String {
    content
        .split('\n')
        .enumerate()
        .map(|(index, line)| {
            let redacted = redact_sensitive_line_assignment(line)
                .unwrap_or_else(|| redact_sensitive_text_value(line));
            if redacted != line {
                redacted_paths.push(format!("$.text.line{}", index + 1));
            }
            redacted
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn redact_sensitive_line_assignment(line: &str) -> Option<String> {
    let separator = line.find([':', '='])?;
    let key_part = &line[..separator];
    if !is_sensitive_snapshot_key(key_part) {
        return None;
    }
    let rest = &line[separator + 1..];
    let leading_len = rest.len() - rest.trim_start().len();
    let leading = &rest[..leading_len];
    let value = rest[leading_len..].trim_end();
    let trailing_comma = value.ends_with(',');
    let quote = value
        .chars()
        .next()
        .filter(|ch| *ch == '"' || *ch == '\'')
        .unwrap_or('\0');
    let replacement = if quote == '\0' {
        REDACTED_SECRET.to_string()
    } else {
        format!("{quote}{REDACTED_SECRET}{quote}")
    };
    Some(format!(
        "{}{}{}{}",
        &line[..separator + 1],
        leading,
        replacement,
        if trailing_comma { "," } else { "" }
    ))
}

fn redact_sensitive_text_value(value: &str) -> String {
    let patterns = [
        (
            r#"(?i)\b(Authorization\s*:\s*Bearer\s+)[^\s"',;)\]}]+"#,
            "$1<redacted-token>",
        ),
        (
            r#"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            "$1<redacted-token>",
        ),
        (
            r#"(?i)\b((?:access_token|refresh_token|id_token|api_key|apiKey|token|secret|password|client_secret)=)[^&\s"',;)\]}]+"#,
            "$1<redacted-secret>",
        ),
    ];
    patterns
        .iter()
        .fold(value.to_string(), |current, (pattern, replacement)| {
            Regex::new(pattern)
                .map(|regex| regex.replace_all(&current, *replacement).to_string())
                .unwrap_or(current)
        })
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

fn hash_text(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
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

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::paths::set_portable_data_dir_override;
    use std::env;

    #[test]
    fn first_portable_launch_creates_fresh_canonical_state() {
        let portable_root = temp_test_dir("portable-parent").join("portable-data");
        let _override = PortableDataDirOverrideGuard::set(portable_root.clone());

        let store = ClientStateStore::portable().unwrap();

        assert_eq!(store.root(), portable_root.join(CLIENT_STATE_DIR));
        assert!(store.root().join(SNAPSHOT_DIR).is_dir());
        assert!(store.root().join("activity").is_dir());
        for collection in COLLECTIONS {
            assert!(store.collection_path(collection).unwrap().is_file());
            assert_eq!(
                store.read_collection(collection).unwrap()["items"],
                json!([])
            );
        }
    }

    struct PortableDataDirOverrideGuard {
        previous: Option<PathBuf>,
    }

    impl PortableDataDirOverrideGuard {
        fn set(path: PathBuf) -> Self {
            Self {
                previous: set_portable_data_dir_override(Some(path)),
            }
        }
    }

    impl Drop for PortableDataDirOverrideGuard {
        fn drop(&mut self) {
            set_portable_data_dir_override(self.previous.take());
        }
    }

    #[test]
    fn state_store_creates_json_collections() {
        let dir = temp_test_dir("collections");
        let store = ClientStateStore::new(dir.clone()).unwrap();

        for collection in COLLECTIONS {
            let document = store.read_collection(collection).unwrap();
            assert_eq!(document["schemaVersion"], STATE_SCHEMA_VERSION);
            assert_eq!(document["collection"], *collection);
            assert!(store.collection_path(collection).unwrap().exists());
        }
    }

    #[test]
    fn state_store_writes_settings_targets_pairings_skills_and_pins() {
        let dir = temp_test_dir("writes");
        let store = ClientStateStore::new(dir).unwrap();

        store
            .write_collection("settings", json!({"items": [{"key": "serverProfile"}]}))
            .unwrap();
        store
            .write_collection("targets", json!({"items": [{"target": "opencode"}]}))
            .unwrap();
        store
            .write_collection("pairings", json!({"items": [{"agent": "codex"}]}))
            .unwrap();
        store
            .write_collection("skills", json!({"items": [{"skill": "review"}]}))
            .unwrap();
        store
            .write_collection(
                "pins",
                json!({"items": [{"skill": "review", "version": "1"}]}),
            )
            .unwrap();

        assert_eq!(
            store.read_collection("targets").unwrap()["items"][0]["target"],
            "opencode"
        );
        assert_eq!(
            store.read_collection("pins").unwrap()["items"][0]["version"],
            "1"
        );
    }

    #[test]
    fn state_store_activity_log_is_jsonl_and_filterable() {
        let dir = temp_test_dir("activity");
        let store = ClientStateStore::new(dir).unwrap();
        let log = store.activity_log();
        log.append("target.config.applied", json!({"target": "opencode"}))
            .unwrap();
        log.append("skill.hidden", json!({"target": "codex"}))
            .unwrap();

        let listed = log.list(&json!({"target": "opencode"})).unwrap();
        let events = listed["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "target.config.applied");
        assert!(
            fs::read_to_string(listed["path"].as_str().unwrap())
                .unwrap()
                .lines()
                .all(|line| serde_json::from_str::<Value>(line).is_ok())
        );
    }

    #[test]
    fn state_store_snapshot_store_can_list_and_restore() {
        let dir = temp_test_dir("snapshots");
        let store = ClientStateStore::new(dir).unwrap();
        let source = store.root().join("target-config.json");
        fs::write(&source, r#"{"before":true}"#).unwrap();
        let snapshot = store
            .snapshot_store()
            .capture("opencode", &source, json!({"operation": "test"}))
            .unwrap();
        fs::write(&source, r#"{"after":true}"#).unwrap();

        let listed = store
            .snapshot_store()
            .list(&json!({"target": "opencode"}))
            .unwrap();
        assert_eq!(listed["snapshots"].as_array().unwrap().len(), 1);

        let restored = store
            .snapshot_store()
            .restore(&snapshot.snapshot_id)
            .unwrap();
        assert_eq!(restored["status"], "restored");
        assert_eq!(fs::read_to_string(&source).unwrap(), r#"{"before":true}"#);
    }

    #[test]
    fn state_store_snapshot_redacts_known_credential_fields() {
        let dir = temp_test_dir("snapshot-redaction");
        let store = ClientStateStore::new(dir).unwrap();
        let source = store.root().join("target-config.json");
        fs::write(
            &source,
            r#"{"headers":{"X-LicoLite-Api-Key":"old-token"},"nested":{"apiKey":"server-key","secretRef":"secret://lico/ref"},"webUrl":"https://example.test/file?access_token=url-token&plain=ok"}"#,
        )
        .unwrap();

        let snapshot = store
            .snapshot_store()
            .capture("opencode", &source, json!({"operation": "test"}))
            .unwrap();
        let snapshot_raw = fs::read_to_string(&snapshot.snapshot_path).unwrap();

        assert!(!snapshot_raw.contains("old-token"));
        assert!(!snapshot_raw.contains("server-key"));
        assert!(!snapshot_raw.contains("url-token"));
        assert!(snapshot_raw.contains(REDACTED_SECRET));
        assert!(snapshot_raw.contains("secret://lico/ref"));

        let snapshot_doc: Value = serde_json::from_str(&snapshot_raw).unwrap();
        assert_eq!(snapshot_doc["redaction"]["applied"], true);
        assert_eq!(
            snapshot_doc["content"]
                .as_str()
                .unwrap()
                .contains(REDACTED_SECRET),
            true
        );

        fs::write(&source, r#"{"after":true}"#).unwrap();
        let restored = store
            .snapshot_store()
            .restore(&snapshot.snapshot_id)
            .unwrap();
        assert_eq!(restored["redactionApplied"], true);
        let restored_content = fs::read_to_string(&source).unwrap();
        assert!(restored_content.contains(REDACTED_SECRET));
        assert!(!restored_content.contains("old-token"));
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-client-state-{}-{}", name, timestamp()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
