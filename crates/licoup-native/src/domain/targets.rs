mod binaries;
mod catalog;
mod discovery;
mod manual;
mod model_catalog;
mod parameters;
mod platform_paths;
mod probe_pool;
mod processes;
mod runtime_binding;
mod scan_merge;
mod support;
mod target_cache;

use anyhow::Result;
use serde_json::Value;
use std::path::PathBuf;

pub use catalog::{AdapterCapabilities, TargetCandidate};

pub fn scan_targets() -> Result<Value> {
    discovery::scan_targets()
}

pub fn scan_targets_with_params(params: &Value) -> Result<Value> {
    discovery::scan_targets_with_params(params)
}

pub(crate) fn available_runtime_executable(target: &str) -> Option<PathBuf> {
    runtime_binding::available_runtime_executable(target)
}

pub fn add_target(params: &Value) -> Result<Value> {
    manual::add_target(params)
}

pub fn inspect_target(target: &str) -> Result<Value> {
    discovery::inspect_target(target)
}

pub fn inspect_target_with_params(params: &Value) -> Result<Value> {
    discovery::inspect_target_with_params(params)
}

#[cfg(test)]
mod tests;
