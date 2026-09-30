//! Stable command entry points over the local archive-job store.

use anyhow::Result;
use serde_json::Value;

use super::store::ArchiveJobStore;

pub fn create(port: &crate::port::AgentTargetPort, params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.create(port, params)
}

pub fn preview(port: &crate::port::AgentTargetPort, params: &Value) -> Result<Value> {
    super::plan::preview(port, params)
}

pub fn status(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.status(params)
}

pub fn list(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.list(params)
}

pub fn events(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.events(params)
}

pub fn cancel(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.cancel(params)
}

pub fn drain(port: &crate::port::AgentTargetPort, params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.drain(port, params)
}
