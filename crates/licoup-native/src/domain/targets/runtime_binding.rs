use super::discovery::scan_targets_with_store;
use super::target_cache::cached_runtime_executable;
use crate::platform::client_state::ClientStateStore;
use crate::platform::runtime_adapters;
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

fn portable_target_store() -> Option<ClientStateStore> {
    let root = crate::platform::paths::portable_data_dir().ok()?;
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
