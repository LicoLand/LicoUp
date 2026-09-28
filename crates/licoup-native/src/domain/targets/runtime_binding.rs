use super::catalog::normalize_target;
use super::discovery::scan_targets_with_store;
use super::manual::manual_targets_read_only;
use super::target_cache::cached_runtime_executable;
use crate::platform::client_state::ClientStateStore;
use crate::platform::runtime_adapters::{self, RuntimeAdapterError};
use serde_json::json;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

const MAX_TARGET_STORE_ROOTS: usize = 4;
static PORTABLE_TARGET_STORES: OnceLock<Mutex<VecDeque<(PathBuf, ClientStateStore)>>> =
    OnceLock::new();

/// Resolve the single local executable advertised by target discovery for a
/// runtime that has a conversation driver. Local agents are client-accessible
/// by default, so parity evidence no longer gates the binding; callers still
/// revalidate immediately before launch, which prevents a remote command from
/// choosing a PATH entry or supplying a local execution path.
pub(super) fn available_runtime_executable(target: &str) -> Option<PathBuf> {
    runtime_adapters::runtime_driver_profile(target)?;
    let store = portable_target_store()?;
    if let Some(executable) = cached_runtime_executable(&store, target) {
        return Some(executable);
    }
    // Cache miss: refresh discovery through the same client-state owner and
    // re-read the coherent projection instead of scanning the response.
    scan_targets_with_store(&json!({}), &store).ok()?;
    cached_runtime_executable(&store, target)
}

/// A saved local binary path is an explicit user choice. It is kept separate
/// from automatic discovery-cache routes so a stale automatic route cannot be
/// mistaken for a manual override.
pub(super) fn manual_runtime_executable(
    target: &str,
) -> Result<Option<PathBuf>, RuntimeAdapterError> {
    let store = ClientStateStore::portable_read_only()
        .map_err(|_| RuntimeAdapterError::ExecutableUnavailable)?;
    manual_runtime_executable_from_store(&store, target)
}

pub(crate) fn manual_runtime_executable_from_store(
    store: &ClientStateStore,
    target: &str,
) -> Result<Option<PathBuf>, RuntimeAdapterError> {
    let normalized = normalize_target(target);
    let manuals =
        manual_targets_read_only(store).map_err(|_| RuntimeAdapterError::ExecutableUnavailable)?;
    Ok(manuals
        .into_iter()
        .find(|manual| manual.target == normalized && manual.location == "local")
        .and_then(|manual| manual.binary_path)
        .filter(|path| path.is_absolute()))
}

fn portable_target_store() -> Option<ClientStateStore> {
    let root = licoup_foundation::platform::paths::portable_data_dir().ok()?;
    let stores = PORTABLE_TARGET_STORES.get_or_init(|| Mutex::new(VecDeque::new()));
    let mut stores = stores
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(position) = stores.iter().position(|(candidate, _)| candidate == &root) {
        let entry = stores
            .remove(position)
            .expect("target store position exists");
        let store = entry.1.clone();
        stores.push_back(entry);
        return Some(store);
    }
    let store = ClientStateStore::portable().ok()?;
    if stores.len() == MAX_TARGET_STORE_ROOTS {
        stores.pop_front();
    }
    stores.push_back((root, store.clone()));
    Some(store)
}
