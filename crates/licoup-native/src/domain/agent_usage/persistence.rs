//! Local-only report retention and retrieval.

use super::contract::{
    AGENT_USAGE_MODE, AGENT_USAGE_SCHEMA_VERSION, AGENT_USAGE_TOKEN_SOURCE_MODE, MAX_REPORTS,
    REPORT_COLLECTION,
};
use crate::domain::conversation::parameters::text_param;
use crate::platform::client_state::ClientStateStore;
use anyhow::Result;
use serde_json::Value;
use std::path::PathBuf;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub(super) fn persist_report(params: &Value, report: &Value) -> Result<()> {
    let store = client_state_store(params)?;
    let mut collection = store.read_collection(REPORT_COLLECTION)?;
    let mut items = collection
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(is_current_report)
        .collect::<Vec<_>>();
    items.push(report.clone());
    sort_reports_by_generated_at(&mut items);
    if items.len() > MAX_REPORTS {
        items = items[items.len() - MAX_REPORTS..].to_vec();
    }
    if let Some(object) = collection.as_object_mut() {
        object.insert("items".to_owned(), Value::Array(items));
    }
    store
        .write_collection(REPORT_COLLECTION, collection)
        .map(|_| ())
}

pub(super) fn read_retained_reports(
    params: &Value,
    agent_filter: Option<&str>,
    limit: usize,
) -> Result<Vec<Value>> {
    let store = client_state_store(params)?;
    let mut collection = store.read_collection(REPORT_COLLECTION)?;
    let stored_items = collection
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut retained_items = stored_items
        .iter()
        .filter(|report| is_current_report(report))
        .cloned()
        .collect::<Vec<_>>();
    sort_reports_by_generated_at(&mut retained_items);
    if retained_items != stored_items {
        if let Some(object) = collection.as_object_mut() {
            object.insert("items".to_owned(), Value::Array(retained_items.clone()));
        }
        store.write_collection(REPORT_COLLECTION, collection)?;
    }
    let mut reports = retained_items
        .into_iter()
        .filter(|report| {
            agent_filter
                .map(|agent_id| report_has_agent(report, agent_id))
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    if reports.len() > limit {
        reports = reports[reports.len() - limit..].to_vec();
    }
    reports.reverse();
    Ok(reports)
}

pub(super) fn client_state_store(params: &Value) -> Result<ClientStateStore> {
    if let Some(path) = text_param(params, &["stateRoot"])
        && !path.trim().is_empty()
    {
        return ClientStateStore::new(PathBuf::from(path));
    }
    ClientStateStore::portable()
}

fn is_current_report(report: &Value) -> bool {
    report.get("schemaVersion").and_then(Value::as_u64) == Some(AGENT_USAGE_SCHEMA_VERSION as u64)
        && report.get("mode").and_then(Value::as_str) == Some(AGENT_USAGE_MODE)
        && report.get("tokenSourceMode").and_then(Value::as_str)
            == Some(AGENT_USAGE_TOKEN_SOURCE_MODE)
        && report_generated_at(report).is_some()
}

fn report_generated_at(report: &Value) -> Option<i128> {
    report
        .get("generatedAt")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .map(|value| value.unix_timestamp_nanos())
}

fn sort_reports_by_generated_at(reports: &mut [Value]) {
    reports.sort_by_key(|report| report_generated_at(report).unwrap_or(i128::MIN));
}

fn report_has_agent(report: &Value, agent_id: &str) -> bool {
    report
        .get("agents")
        .and_then(Value::as_array)
        .is_some_and(|agents| {
            agents
                .iter()
                .any(|agent| agent.get("agentId").and_then(Value::as_str) == Some(agent_id))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("lico-agent-usage-persistence-{nonce}"))
    }

    fn report(index: usize, agent_id: &str) -> Value {
        json!({
            "schemaVersion": AGENT_USAGE_SCHEMA_VERSION,
            "mode": AGENT_USAGE_MODE,
            "tokenSourceMode": AGENT_USAGE_TOKEN_SOURCE_MODE,
            "generatedAt": format!("2026-07-{:02}T00:00:00Z", index + 1),
            "agents": [{"agentId": agent_id}]
        })
    }

    #[test]
    fn retention_is_local_bounded_current_schema_and_filterable() {
        let root = temp_root();
        let params = json!({"stateRoot": root.to_string_lossy()});
        for index in 0..(MAX_REPORTS + 2) {
            let agent = if index % 2 == 0 { "codex" } else { "cursor" };
            persist_report(&params, &report(index, agent)).unwrap();
        }
        let store = client_state_store(&params).unwrap();
        let retained = store.read_collection(REPORT_COLLECTION).unwrap();
        assert_eq!(retained["items"].as_array().unwrap().len(), MAX_REPORTS);
        let codex = read_retained_reports(&params, Some("codex"), 3).unwrap();
        assert_eq!(codex.len(), 3);
        assert!(codex.iter().all(|item| report_has_agent(item, "codex")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retrieval_removes_noncurrent_report_contracts() {
        let root = temp_root();
        let params = json!({"stateRoot": root.to_string_lossy()});
        let store = client_state_store(&params).unwrap();
        store
            .write_collection(
                REPORT_COLLECTION,
                json!({
                    "items": [
                        {
                            "schemaVersion": 999,
                            "mode": "invalid-contract",
                            "generatedAt": "2026-07-01T00:00:00Z"
                        },
                        report(1, "codex")
                    ]
                }),
            )
            .unwrap();
        let reports = read_retained_reports(&params, None, 10).unwrap();
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0]["schemaVersion"], AGENT_USAGE_SCHEMA_VERSION);
        fs::remove_dir_all(root).unwrap();
    }
}
