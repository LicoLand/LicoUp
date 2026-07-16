use super::discovery::scan_targets_with_params;
use super::target_cache::cached_runtime_executable;
use crate::platform::runtime_adapters;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

/// Resolve the single local executable that is both advertised by target
/// discovery and bound to the canonical native-conversation readiness evidence.
/// Callers must still
/// revalidate immediately before launch; this prevents a remote command from
/// choosing a PATH entry or supplying a local execution path.
pub(super) fn ready_runtime_executable(target: &str) -> Option<PathBuf> {
    if !runtime_adapters::runtime_driver_profile(target)
        .is_some_and(|profile| profile.readiness == "ready")
    {
        return None;
    }
    if let Some(executable) = cached_runtime_executable(target)
        && runtime_adapters::runtime_evidence_matches(target, &executable)
    {
        return Some(executable);
    }
    let scan = scan_targets_with_params(&json!({})).ok()?;
    let candidates = scan.get("candidates")?.as_array()?;
    let mut matched = BTreeSet::<PathBuf>::new();
    for candidate in candidates {
        if candidate.get("target").and_then(Value::as_str) != Some(target)
            || candidate.get("status").and_then(Value::as_str) == Some("not-detected")
            || !candidate
                .get("supportedActions")
                .and_then(Value::as_array)
                .is_some_and(|actions| {
                    actions
                        .iter()
                        .any(|action| action.as_str() == Some("runtime.message.send"))
                })
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
    let executable = matched.into_iter().next()?;
    runtime_adapters::runtime_evidence_matches(target, &executable).then_some(executable)
}
