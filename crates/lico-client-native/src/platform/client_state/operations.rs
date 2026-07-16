use anyhow::Result;
use serde_json::{Value, json};

use super::activity::ActivityLog;
use super::collections::ClientStateStore;
use super::snapshots::SnapshotStore;

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
            "target": "snapshot",
            "snapshotId": snapshot_id
        }),
    )?;
    Ok(json!({
        "ok": true,
        "restore": result,
        "activity": activity
    }))
}
