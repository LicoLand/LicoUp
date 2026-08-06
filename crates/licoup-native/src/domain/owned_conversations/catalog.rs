use anyhow::{Result, anyhow, bail};
use regex::Regex;
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

use crate::platform::paths::portable_data_dir;

const PROJECTIONS_FILE: &str = "agent-conversation-projections.json";
const SCHEMA_VERSION: u64 = 1;
const MAX_AGENTS: usize = 32;
const MAX_SESSIONS_PER_AGENT: usize = 100;
const MAX_EXPORT_SESSIONS: usize = 500;
const MAX_SEARCH_HITS: usize = 100;
const MAX_ID_BYTES: usize = 256;
const MAX_QUERY_BYTES: usize = 4 * 1024;
const MAX_PATH_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OwnedConversationMatchMode {
    Keyword,
    Regex,
}

impl OwnedConversationMatchMode {
    pub fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "keyword" | "text" => Ok(Self::Keyword),
            "regex" | "regexp" => Ok(Self::Regex),
            _ => Err(anyhow!("owned_conversation_match_mode_invalid")),
        }
    }
}

#[derive(Clone, Debug)]
pub struct OwnedConversationRecord {
    pub agent_id: String,
    pub session: Value,
}

impl OwnedConversationRecord {
    pub fn id(&self) -> &str {
        self.session
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
    }

    pub fn native_session_id(&self) -> &str {
        self.session
            .get("nativeSessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
    }

    pub fn matches_id(&self, needle: &str) -> bool {
        let needle = needle.trim();
        if needle.is_empty() {
            return false;
        }
        self.id() == needle || self.native_session_id() == needle
    }

    fn searchable_text(&self) -> String {
        let mut parts = Vec::new();
        for key in ["id", "nativeSessionId", "title", "workingDirectory", "sourcePath"] {
            if let Some(value) = self.session.get(key).and_then(Value::as_str) {
                if !value.is_empty() {
                    parts.push(value.to_owned());
                }
            }
        }
        parts.push(self.agent_id.clone());
        if let Some(messages) = self.session.get("messages").and_then(Value::as_array) {
            for message in messages {
                if let Some(text) = message.get("text").and_then(Value::as_str) {
                    if !text.is_empty() {
                        parts.push(text.to_owned());
                    }
                }
            }
        }
        parts.join("\n")
    }

    fn summary_json(&self) -> Value {
        json!({
            "agentId": self.agent_id,
            "id": self.id(),
            "nativeSessionId": self.native_session_id(),
            "title": self.session.get("title").cloned().unwrap_or(json!("")),
            "createdAt": self.session.get("createdAt").cloned().unwrap_or(json!("")),
            "updatedAt": self.session.get("updatedAt").cloned().unwrap_or(json!("")),
            "messageCount": self.session.get("messageCount").cloned().unwrap_or(json!(0)),
            "workingDirectory": self.session.get("workingDirectory").cloned().unwrap_or(json!("")),
            "sourcePath": self.session.get("sourcePath").cloned().unwrap_or(json!("")),
            "sourceKind": self.session.get("sourceKind").cloned().unwrap_or(json!("")),
            "adapterId": self.session.get("adapterId").cloned().unwrap_or(json!("")),
        })
    }
}

fn client_state_root() -> Result<PathBuf> {
    Ok(portable_data_dir()?.join("client-state"))
}

fn projections_path(root: &Path) -> PathBuf {
    root.join(PROJECTIONS_FILE)
}

fn load_projection_document(root: &Path) -> Result<Value> {
    let path = projections_path(root);
    if !path.is_file() {
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "sessionsByAgent": {},
        }));
    }
    let bytes = fs::read(&path)?;
    let value: Value = serde_json::from_slice(&bytes)?;
    Ok(value)
}

fn save_projection_document(root: &Path, document: &Value) -> Result<()> {
    let path = projections_path(root);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(document)?;
    crate::platform::file_security::atomic_write_private_text(&path, &text)?;
    Ok(())
}

fn load_records() -> Result<Vec<OwnedConversationRecord>> {
    let portable_root = portable_data_dir()?;
    let root = portable_root.join("client-state");
    let document = load_projection_document(&root)?;
    let mut records = Vec::new();
    let Some(by_agent) = document.get("sessionsByAgent").and_then(Value::as_object) else {
        return Ok(records);
    };
    for (agent_id, sessions) in by_agent.iter().take(MAX_AGENTS) {
        let agent_id = agent_id.trim();
        if agent_id.is_empty() {
            continue;
        }
        let Some(sessions) = sessions.as_array() else {
            continue;
        };
        for session in sessions.iter().take(MAX_SESSIONS_PER_AGENT) {
            if !session.is_object() {
                continue;
            }
            let id = session
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            if id.is_empty() {
                continue;
            }
            records.push(OwnedConversationRecord {
                agent_id: agent_id.to_owned(),
                session: session.clone(),
            });
        }
    }
    // Surface the default group room as a first-class owned conversation.
    if let Ok(store) =
        crate::domain::group_conversation::GroupConversationStore::open(&portable_root)
    {
        if let Ok(Some(room)) = store.load("lico-group-default") {
            let mut session = Map::new();
            session.insert("id".into(), json!(room.id));
            session.insert("agentId".into(), json!("lico-group"));
            session.insert("title".into(), json!(room.title));
            session.insert("createdAt".into(), json!(""));
            session.insert("updatedAt".into(), json!(""));
            session.insert("messages".into(), json!([]));
            session.insert("messageCount".into(), json!(0));
            session.insert(
                "sourceKind".into(),
                json!("lico-owned-group-conversation"),
            );
            session.insert("sourceClient".into(), json!("licoup"));
            session.insert("adapterId".into(), json!("lico-group"));
            session.insert(
                "sourcePath".into(),
                json!(room.transcript_path.to_string_lossy()),
            );
            session.insert(
                "lastLocalOrchestrationSessionId".into(),
                json!(room.last_local_orchestration_session_id),
            );
            session.insert(
                "agentSessions".into(),
                serde_json::to_value(&room.agent_sessions).unwrap_or(json!({})),
            );
            records.push(OwnedConversationRecord {
                agent_id: "lico-group".into(),
                session: Value::Object(session),
            });
        }
    }
    Ok(records)
}

pub fn list_owned_conversations(limit: usize) -> Result<Value> {
    let records = load_records()?;
    let limit = limit.clamp(1, MAX_SEARCH_HITS);
    Ok(json!({
        "ok": true,
        "count": records.len().min(limit),
        "total": records.len(),
        "conversations": records.iter().take(limit).map(OwnedConversationRecord::summary_json).collect::<Vec<_>>(),
    }))
}

pub fn get_owned_conversation(conversation_id: &str) -> Result<Value> {
    let id = conversation_id.trim();
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        bail!("owned_conversation_id_invalid");
    }
    let records = load_records()?;
    let Some(record) = records.into_iter().find(|record| record.matches_id(id)) else {
        bail!("owned_conversation_not_found");
    };
    Ok(json!({
        "ok": true,
        "conversation": {
            "agentId": record.agent_id,
            "session": record.session,
        }
    }))
}

pub fn search_owned_conversations(
    query: &str,
    mode: OwnedConversationMatchMode,
    limit: usize,
) -> Result<Value> {
    let query = query.trim();
    if query.is_empty() || query.len() > MAX_QUERY_BYTES {
        bail!("owned_conversation_query_invalid");
    }
    let records = load_records()?;
    let limit = limit.clamp(1, MAX_SEARCH_HITS);
    let mut hits = Vec::new();
    match mode {
        OwnedConversationMatchMode::Keyword => {
            let needle = query.to_ascii_lowercase();
            for record in records {
                if record.searchable_text().to_ascii_lowercase().contains(&needle) {
                    hits.push(record.summary_json());
                    if hits.len() >= limit {
                        break;
                    }
                }
            }
        }
        OwnedConversationMatchMode::Regex => {
            let regex = Regex::new(query).map_err(|_| anyhow!("owned_conversation_regex_invalid"))?;
            for record in records {
                if regex.is_match(&record.searchable_text()) {
                    hits.push(record.summary_json());
                    if hits.len() >= limit {
                        break;
                    }
                }
            }
        }
    }
    Ok(json!({
        "ok": true,
        "matchMode": match mode {
            OwnedConversationMatchMode::Keyword => "keyword",
            OwnedConversationMatchMode::Regex => "regex",
        },
        "query": query,
        "count": hits.len(),
        "conversations": hits,
    }))
}

pub fn export_owned_conversations(
    destination_path: &str,
    conversation_ids: &[String],
) -> Result<Value> {
    let destination = destination_path.trim();
    if destination.is_empty() || destination.len() > MAX_PATH_BYTES {
        bail!("owned_conversation_export_path_invalid");
    }
    let path = PathBuf::from(destination);
    if path.as_os_str().is_empty() || destination.contains('\0') {
        bail!("owned_conversation_export_path_invalid");
    }
    let records = load_records()?;
    let selected: Vec<OwnedConversationRecord> = if conversation_ids.is_empty() {
        records.into_iter().take(MAX_EXPORT_SESSIONS).collect()
    } else {
        let wanted: std::collections::HashSet<&str> = conversation_ids
            .iter()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .collect();
        records
            .into_iter()
            .filter(|record| {
                wanted.contains(record.id()) || wanted.contains(record.native_session_id())
            })
            .take(MAX_EXPORT_SESSIONS)
            .collect()
    };
    if selected.is_empty() {
        bail!("owned_conversation_export_empty");
    }
    let mut sessions_by_agent: Map<String, Value> = Map::new();
    for record in &selected {
        let entry = sessions_by_agent
            .entry(record.agent_id.clone())
            .or_insert_with(|| json!([]));
        if let Some(list) = entry.as_array_mut() {
            list.push(record.session.clone());
        }
    }
    let bundle = json!({
        "ok": true,
        "kind": "lico-owned-conversations-export",
        "schemaVersion": SCHEMA_VERSION,
        "exportedAtUnixMs": chrono_unix_ms(),
        "count": selected.len(),
        "sessionsByAgent": sessions_by_agent,
    });
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let text = serde_json::to_string_pretty(&bundle)?;
    crate::platform::file_security::atomic_write_private_text(&path, &text)?;
    Ok(json!({
        "ok": true,
        "path": path.to_string_lossy(),
        "count": selected.len(),
    }))
}

pub fn import_owned_conversations(source_path: &str, replace_existing: bool) -> Result<Value> {
    let source = source_path.trim();
    if source.is_empty() || source.len() > MAX_PATH_BYTES {
        bail!("owned_conversation_import_path_invalid");
    }
    let path = PathBuf::from(source);
    if !path.is_file() {
        bail!("owned_conversation_import_not_found");
    }
    let bytes = fs::read(&path)?;
    let bundle: Value = serde_json::from_slice(&bytes)?;
    let kind = bundle
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if kind != "lico-owned-conversations-export"
        && bundle.get("sessionsByAgent").is_none()
    {
        bail!("owned_conversation_import_kind_invalid");
    }
    let incoming = bundle
        .get("sessionsByAgent")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("owned_conversation_import_payload_invalid"))?;
    let root = client_state_root()?;
    let mut document = load_projection_document(&root)?;
    let sessions_by_agent = document
        .as_object_mut()
        .ok_or_else(|| anyhow!("owned_conversation_projection_invalid"))?
        .entry("sessionsByAgent".to_owned())
        .or_insert_with(|| json!({}));
    let store = sessions_by_agent
        .as_object_mut()
        .ok_or_else(|| anyhow!("owned_conversation_projection_invalid"))?;

    let mut imported = 0usize;
    let mut replaced = 0usize;
    for (agent_id, sessions) in incoming.iter().take(MAX_AGENTS) {
        let agent_id = agent_id.trim();
        if agent_id.is_empty() {
            continue;
        }
        let Some(sessions) = sessions.as_array() else {
            continue;
        };
        let entry = store
            .entry(agent_id.to_owned())
            .or_insert_with(|| json!([]));
        let list = entry
            .as_array_mut()
            .ok_or_else(|| anyhow!("owned_conversation_projection_invalid"))?;
        for session in sessions.iter().take(MAX_SESSIONS_PER_AGENT) {
            if !session.is_object() {
                continue;
            }
            let id = session
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            if id.is_empty() {
                continue;
            }
            if let Some(index) = list.iter().position(|existing| {
                existing
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    == id
            }) {
                if replace_existing {
                    list[index] = session.clone();
                    replaced += 1;
                }
                continue;
            }
            if list.len() >= MAX_SESSIONS_PER_AGENT {
                continue;
            }
            list.push(session.clone());
            imported += 1;
        }
    }
    document
        .as_object_mut()
        .ok_or_else(|| anyhow!("owned_conversation_projection_invalid"))?
        .insert("schemaVersion".into(), json!(SCHEMA_VERSION));
    save_projection_document(&root, &document)?;
    Ok(json!({
        "ok": true,
        "imported": imported,
        "replaced": replaced,
        "path": path.to_string_lossy(),
    }))
}

fn chrono_unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::paths::set_portable_data_dir_override;
    use uuid::Uuid;

    struct PortableGuard(Option<PathBuf>);
    impl Drop for PortableGuard {
        fn drop(&mut self) {
            set_portable_data_dir_override(self.0.take());
        }
    }

    fn temp_portable() -> (PathBuf, PortableGuard) {
        let root = std::env::temp_dir().join(format!("lico-owned-{}", Uuid::new_v4()));
        fs::create_dir_all(root.join("client-state")).unwrap();
        let previous = set_portable_data_dir_override(Some(root.clone()));
        (root, PortableGuard(previous))
    }

    #[test]
    fn get_search_export_import_round_trip() {
        let (root, _guard) = temp_portable();
        let projections = root
            .join("client-state")
            .join("agent-conversation-projections.json");
        fs::write(
            &projections,
            serde_json::to_vec_pretty(&json!({
                "schemaVersion": 1,
                "sessionsByAgent": {
                    "lico-default-orchestrator": [{
                        "id": "lico-local-1",
                        "agentId": "lico-default-orchestrator",
                        "title": "你是什么模型？",
                        "createdAt": "2026-08-03T10:54:00Z",
                        "updatedAt": "2026-08-03T10:55:00Z",
                        "nativeSessionId": "native-antigravity-1",
                        "adapterId": "lico-orchestration",
                        "sourceKind": "lico-owned-orchestration",
                        "sourceClient": "licoup",
                        "messages": [
                            {"role": "user", "text": "你是什么模型？"},
                            {"role": "assistant", "text": "Claude Opus"}
                        ],
                        "messageCount": 2
                    }]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let got = get_owned_conversation("lico-local-1").unwrap();
        assert_eq!(got["ok"], true);
        assert_eq!(
            got["conversation"]["session"]["nativeSessionId"],
            "native-antigravity-1"
        );

        let by_native = get_owned_conversation("native-antigravity-1").unwrap();
        assert_eq!(by_native["conversation"]["session"]["id"], "lico-local-1");

        let keyword = search_owned_conversations(
            "Claude Opus",
            OwnedConversationMatchMode::Keyword,
            10,
        )
        .unwrap();
        assert_eq!(keyword["count"], 1);

        let regex = search_owned_conversations(
            r"模型|Opus",
            OwnedConversationMatchMode::Regex,
            10,
        )
        .unwrap();
        assert_eq!(regex["count"], 1);

        let export_path = root.join("export.json");
        let exported = export_owned_conversations(
            export_path.to_str().unwrap(),
            &["lico-local-1".into()],
        )
        .unwrap();
        assert_eq!(exported["count"], 1);

        fs::write(
            &projections,
            serde_json::to_vec_pretty(&json!({
                "schemaVersion": 1,
                "sessionsByAgent": {}
            }))
            .unwrap(),
        )
        .unwrap();
        let imported =
            import_owned_conversations(export_path.to_str().unwrap(), true).unwrap();
        assert_eq!(imported["imported"], 1);
        let restored = get_owned_conversation("lico-local-1").unwrap();
        assert_eq!(restored["ok"], true);

        let _ = fs::remove_dir_all(root);
    }
}
