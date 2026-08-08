//! LicoUp-owned subordinate handoff records.
//!
//! The main agent only requests work. LicoUp accepts, runs the subordinate,
//! detects completion, and resumes the original main conversation.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const HANDOFF_SCHEMA_VERSION: &str = "licoup.subagent.handoff.v1";
pub const RECEIPT_SCHEMA_VERSION: &str = "licoup.subagent.receipt.v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HandoffState {
    Accepted,
    Running,
    Completed,
    Failed,
    CancelRequested,
}

impl HandoffState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::CancelRequested => "cancel-requested",
        }
    }
}

/// Whether LicoUp should open a fresh subordinate session or resume one.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SessionMode {
    #[default]
    New,
    Resume,
}

impl SessionMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::New => "new",
            Self::Resume => "resume",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "new" => Some(Self::New),
            "resume" => Some(Self::Resume),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandoffRecord {
    pub schema_version: String,
    pub dispatch_id: String,
    pub operation: String,
    pub manager_agent_id: String,
    pub agent_id: String,
    pub state: HandoffState,
    #[serde(default)]
    pub session_mode: SessionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_conversation_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    pub updated_at_unix_ms: u64,
}

impl HandoffRecord {
    pub fn new(
        dispatch_id: impl Into<String>,
        operation: impl Into<String>,
        manager_agent_id: impl Into<String>,
        agent_id: impl Into<String>,
        session_mode: SessionMode,
        main_conversation_path: Option<String>,
    ) -> Self {
        Self {
            schema_version: HANDOFF_SCHEMA_VERSION.to_owned(),
            dispatch_id: dispatch_id.into(),
            operation: operation.into(),
            manager_agent_id: manager_agent_id.into(),
            agent_id: agent_id.into(),
            state: HandoffState::Accepted,
            session_mode,
            main_conversation_path,
            conversation_path: None,
            error_code: None,
            updated_at_unix_ms: unix_ms_now(),
        }
    }

    pub fn ack_receipt(&self) -> Value {
        let mut receipt = serde_json::json!({
            "schemaVersion": RECEIPT_SCHEMA_VERSION,
            "operation": self.operation,
            "agentId": self.agent_id,
            "state": self.state.as_str(),
            "dispatchId": self.dispatch_id,
            "sessionMode": self.session_mode.as_str(),
            "accepted": true,
        });
        if let Some(path) = &self.main_conversation_path {
            receipt["mainConversationPath"] = Value::String(path.clone());
        }
        if let Some(path) = &self.conversation_path {
            receipt["conversationPath"] = Value::String(path.clone());
        }
        receipt
    }
}

pub fn handoff_root(portable_data: &Path) -> PathBuf {
    portable_data.join("client-state").join("subagent-handoffs")
}

pub fn handoff_path(portable_data: &Path, dispatch_id: &str) -> PathBuf {
    handoff_root(portable_data).join(format!("{dispatch_id}.json"))
}

pub fn persist_handoff(portable_data: &Path, record: &HandoffRecord) -> Result<(), String> {
    let root = handoff_root(portable_data);
    fs::create_dir_all(&root).map_err(|_| "handoff_store_unavailable".to_owned())?;
    let path = handoff_path(portable_data, &record.dispatch_id);
    let body = serde_json::to_vec_pretty(record).map_err(|_| "handoff_encode_failed".to_owned())?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, body).map_err(|_| "handoff_write_failed".to_owned())?;
    fs::rename(&tmp, &path).map_err(|_| "handoff_write_failed".to_owned())?;
    Ok(())
}

pub fn load_handoff(portable_data: &Path, dispatch_id: &str) -> Result<HandoffRecord, String> {
    let path = handoff_path(portable_data, dispatch_id);
    let raw = fs::read_to_string(&path).map_err(|_| "handoff_not_found".to_owned())?;
    serde_json::from_str(&raw).map_err(|_| "handoff_decode_failed".to_owned())
}

pub fn list_handoffs(portable_data: &Path) -> Result<Vec<HandoffRecord>, String> {
    let root = handoff_root(portable_data);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut records = Vec::new();
    let entries = fs::read_dir(&root).map_err(|_| "handoff_store_unavailable".to_owned())?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        if let Ok(record) = serde_json::from_str::<HandoffRecord>(&raw) {
            records.push(record);
        }
    }
    records.sort_by_key(|record| std::cmp::Reverse(record.updated_at_unix_ms));
    Ok(records)
}

pub fn new_dispatch_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    format!("handoff-{nanos}")
}

pub fn unix_ms_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persist_and_load_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "licoup-handoff-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let record = HandoffRecord::new(
            "handoff-1",
            "subagent.delegate",
            "codex",
            "claude",
            SessionMode::Resume,
            Some("/fixture/location/main.jsonl".into()),
        );
        persist_handoff(&dir, &record).unwrap();
        let loaded = load_handoff(&dir, "handoff-1").unwrap();
        assert_eq!(loaded.dispatch_id, "handoff-1");
        assert_eq!(loaded.state, HandoffState::Accepted);
        assert_eq!(loaded.session_mode, SessionMode::Resume);
        assert_eq!(
            loaded.main_conversation_path.as_deref(),
            Some("/fixture/location/main.jsonl")
        );
        let ack = loaded.ack_receipt();
        assert_eq!(ack["accepted"], true);
        assert_eq!(ack["state"], "accepted");
        assert_eq!(ack["sessionMode"], "resume");
        assert_eq!(ack["dispatchId"], "handoff-1");
        let _ = fs::remove_dir_all(&dir);
    }
}
