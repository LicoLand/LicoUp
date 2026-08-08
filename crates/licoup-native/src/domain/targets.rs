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
mod virtual_machine_discovery;

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

/// CLI/runtime executable presence for the adapter management catalog: the
/// agent's official binary names on the automatic search dirs, or a verified
/// product-bundled executable (editor extension or desktop bundle).
pub(crate) fn agent_cli_executable(agent_id: &str) -> Option<PathBuf> {
    let def = catalog::target_def(agent_id).ok()?;
    binaries::find_binary(def.binary_names)
        .or_else(|| binaries::find_extension_bundled_binary(&def))
}

/// Desktop application presence for the adapter management catalog. Only
/// agents with a verified desktop bundle mapping can report detection.
pub(crate) fn agent_desktop_app_detected(agent_id: &str) -> bool {
    binaries::desktop_app_executable(agent_id).is_some()
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
