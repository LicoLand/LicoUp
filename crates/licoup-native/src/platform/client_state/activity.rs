use crate::platform::file_security::{ensure_private_dir, read_private_text_bounded};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use super::{paths, policy, redaction, serialization};

#[derive(Clone, Debug)]
pub struct ActivityLog {
    path: PathBuf,
}

impl ActivityLog {
    pub fn portable() -> Result<Self> {
        let root = paths::portable_state_root()?;
        ensure_private_dir(&root)?;
        ensure_private_dir(&paths::activity_root(&root))?;
        Ok(Self::from_state_root(&root))
    }

    pub(super) fn from_state_root(root: &Path) -> Self {
        Self {
            path: paths::activity_path(root),
        }
    }

    pub fn append(&self, event_type: &str, payload: Value) -> Result<Value> {
        validate_event_type(event_type)?;
        let payload = redaction::redact_activity_payload(payload)?;
        let target = safe_target(&payload).to_string();
        let created_at = serialization::timestamp();
        let event = json!({
            "schemaVersion": policy::STATE_SCHEMA_VERSION,
            "eventId": format!("activity-{created_at}"),
            "type": event_type,
            "target": target,
            "createdAt": created_at,
            "payload": payload,
        });
        let encoded = serde_json::to_string(&event)?;
        ensure!(
            encoded.len() <= policy::MAX_ACTIVITY_EVENT_BYTES,
            "activity event exceeds its bounded size"
        );
        crate::platform::file_security::append_private_line(&self.path, &encoded)?;
        Ok(event)
    }

    pub fn list(&self, filter: &Value) -> Result<Value> {
        let limit = filter
            .get("limit")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(policy::MAX_ACTIVITY_EVENTS)
            .min(policy::MAX_ACTIVITY_EVENTS);
        let mut events = VecDeque::<Value>::with_capacity(limit.min(256));
        if let Some(raw) = read_private_text_bounded(&self.path, policy::MAX_ACTIVITY_FILE_BYTES)? {
            for line in raw.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                ensure!(
                    line.len() <= policy::MAX_ACTIVITY_EVENT_BYTES,
                    "activity event exceeds its bounded size"
                );
                let event: Value = serde_json::from_str(line)?;
                if matches_activity_filter(&event, filter) && limit > 0 {
                    if events.len() == limit {
                        events.pop_front();
                    }
                    events.push_back(event);
                }
            }
        }
        Ok(json!({
            "ok": true,
            "schemaVersion": policy::STATE_SCHEMA_VERSION,
            "path": paths::internal_state_reference(policy::ACTIVITY_DIR, &self.path),
            "events": events.into_iter().collect::<Vec<_>>()
        }))
    }
}

fn validate_event_type(event_type: &str) -> Result<()> {
    ensure!(
        !event_type.is_empty()
            && event_type.len() <= policy::MAX_ACTIVITY_TYPE_BYTES
            && event_type.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-' || byte == b'_'
            }),
        "activity event type is invalid"
    );
    Ok(())
}

fn safe_target(payload: &Value) -> &str {
    payload
        .get("target")
        .and_then(Value::as_str)
        .filter(|target| {
            !target.is_empty()
                && target.len() <= 128
                && target.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric()
                        || byte == b'.'
                        || byte == b'-'
                        || byte == b'_'
                        || byte == b':'
                })
        })
        .unwrap_or("")
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
