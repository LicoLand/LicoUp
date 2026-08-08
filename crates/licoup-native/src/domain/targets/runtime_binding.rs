use super::discovery::scan_targets_with_params;
use super::target_cache::cached_runtime_executable;
use crate::platform::runtime_adapters;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

/// Resolve the single local executable advertised by target discovery for a
/// runtime that has a conversation driver. Local agents are client-accessible
/// by default, so parity evidence no longer gates the binding; callers still
/// revalidate immediately before launch, which prevents a remote command from
/// choosing a PATH entry or supplying a local execution path.
pub(super) fn available_runtime_executable(target: &str) -> Option<PathBuf> {
    if runtime_adapters::runtime_driver_profile(target).is_none() {
        return None;
    }
    if let Some(executable) = cached_runtime_executable(target) {
        return Some(executable);
    }
    let scan = scan_targets_with_params(&json!({})).ok()?;
    let candidates = scan.get("candidates")?.as_array()?;
    let mut matched = BTreeSet::<PathBuf>::new();
    for candidate in candidates {
        if candidate.get("target").and_then(Value::as_str) != Some(target)
            || candidate.get("status").and_then(Value::as_str) == Some("not-detected")
        {
            continue;
        }
        let Some(binary_path) = candidate
            .get("binaryPath")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
        else {
            continue;
        };
        if !binary_path.is_absolute() {
            continue;
        }
        let Some(canonical) = fs::canonicalize(binary_path).ok() else {
            continue;
        };
        matched.insert(canonical);
    }
    if matched.len() != 1 {
        return None;
    }
    matched.into_iter().next()
}
