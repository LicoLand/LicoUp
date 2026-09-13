//! Shared canonical model identities from public catalog facts. Native Agent
//! selectors remain untouched; the registry supplies identity, not entitlement.

mod display;
mod index;
mod source;

use anyhow::{Result, anyhow};
pub use display::model_display_name;
pub use index::RegistrySnapshot;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalModel {
    pub id: String,
    pub display_name: String,
    pub lab_id: String,
    pub family: Option<String>,
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub(crate) struct CatalogDocument {
    pub models: BTreeMap<String, Value>,
    pub providers: BTreeMap<String, ProviderDocument>,
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub(crate) struct ProviderDocument {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub models: BTreeMap<String, Value>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedCatalog {
    source: String,
    fetched_at: String,
    skipped_entries: usize,
    catalog: CatalogDocument,
}

struct RegistryState {
    snapshot: Arc<RegistrySnapshot>,
    signature: Option<(PathBuf, SystemTime, u64)>,
    source: String,
    fetched_at: Option<String>,
    skipped_entries: usize,
}

impl Default for RegistryState {
    fn default() -> Self {
        Self {
            snapshot: Arc::new(RegistrySnapshot::empty()),
            signature: None,
            source: String::new(),
            fetched_at: None,
            skipped_entries: 0,
        }
    }
}

#[derive(Default)]
struct RegistryRuntime {
    state: RwLock<RegistryState>,
    reload: Mutex<()>,
    refresh: Mutex<()>,
}

fn runtime() -> &'static RegistryRuntime {
    static REGISTRY: OnceLock<RegistryRuntime> = OnceLock::new();
    REGISTRY.get_or_init(RegistryRuntime::default)
}

/// No file or network work. Capture one Arc at each report boundary.
pub fn snapshot() -> Arc<RegistrySnapshot> {
    #[cfg(test)]
    {
        return test_snapshot();
    }
    #[cfg(not(test))]
    runtime().snapshot()
}

/// One metadata check per request observes refreshes performed by another
/// native process. Resolvers on the returned Arc perform no I/O.
pub fn refresh_cached_snapshot() -> Arc<RegistrySnapshot> {
    #[cfg(test)]
    {
        return test_snapshot();
    }
    #[cfg(not(test))]
    {
        if let Ok(root) = crate::platform::paths::portable_data_dir_read_only() {
            let _ = runtime().reload_at(&root.join("model-registry/catalog.json"));
        }
        runtime().snapshot()
    }
}

/// An explicitly selected state store owns its catalog too. Keep this
/// request's snapshot separate so an empty store cannot inherit the host
/// catalog or another concurrently inspected store's identities.
pub fn refresh_cached_snapshot_for_state_root(state_root: Option<&Path>) -> Arc<RegistrySnapshot> {
    #[cfg(test)]
    {
        let _ = state_root;
        test_snapshot()
    }
    #[cfg(not(test))]
    {
        match state_root {
            Some(root) => {
                let isolated = RegistryRuntime::default();
                let _ = isolated.reload_at(&root.join("model-registry/catalog.json"));
                isolated.snapshot()
            }
            None => refresh_cached_snapshot(),
        }
    }
}

pub fn read() -> Value {
    let _ = refresh_cached_snapshot();
    runtime().summary(true, "ready", None)
}

/// Only explicit local refresh performs public network requests. A download,
/// parse, or cache-write failure leaves the previous valid snapshot intact.
pub fn refresh() -> Value {
    let _ = refresh_cached_snapshot();
    let result = crate::platform::paths::portable_data_dir_read_only().and_then(|root| {
        runtime().refresh_at(&root.join("model-registry/catalog.json"), source::download)
    });
    match result {
        Ok(changed) => {
            runtime().summary(true, if changed { "refreshed" } else { "unchanged" }, None)
        }
        Err(_) => runtime().summary(false, "unavailable", Some("model_registry_refresh_failed")),
    }
}

impl RegistryRuntime {
    fn snapshot(&self) -> Arc<RegistrySnapshot> {
        Arc::clone(
            &self
                .state
                .read()
                .unwrap_or_else(|error| error.into_inner())
                .snapshot,
        )
    }

    fn reload_at(&self, path: &Path) -> Result<()> {
        let _reload = self
            .reload
            .lock()
            .map_err(|_| anyhow!("model_registry_reload_lock_failed"))?;
        let metadata = match fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(_) => return Err(anyhow!("model_registry_cache_unavailable")),
        };
        let signature = (path.to_owned(), metadata.modified()?, metadata.len());
        if self
            .state
            .read()
            .map_err(|_| anyhow!("model_registry_lock_failed"))?
            .signature
            .as_ref()
            == Some(&signature)
        {
            return Ok(());
        }
        let persisted: PersistedCatalog = serde_json::from_slice(&fs::read(path)?)?;
        let snapshot = Arc::new(RegistrySnapshot::from_document(&persisted.catalog)?);
        let mut state = self
            .state
            .write()
            .map_err(|_| anyhow!("model_registry_lock_failed"))?;
        *state = RegistryState {
            snapshot,
            signature: Some(signature),
            source: persisted.source,
            fetched_at: Some(persisted.fetched_at),
            skipped_entries: persisted.skipped_entries,
        };
        Ok(())
    }

    fn refresh_at(
        &self,
        path: &Path,
        fetch: impl FnOnce() -> Result<source::DownloadedCatalog>,
    ) -> Result<bool> {
        let _refresh = self
            .refresh
            .lock()
            .map_err(|_| anyhow!("model_registry_refresh_lock_failed"))?;
        let downloaded = fetch()?;
        let next = RegistrySnapshot::from_document(&downloaded.catalog)?;
        let changed = next.revision() != self.snapshot().revision();
        let persisted = PersistedCatalog {
            source: downloaded.source,
            fetched_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)?
                .as_millis()
                .to_string(),
            skipped_entries: downloaded.skipped_entries,
            catalog: downloaded.catalog,
        };
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("model_registry_cache_path_invalid"))?;
        crate::platform::file_security::ensure_private_dir(parent)?;
        crate::platform::file_security::atomic_write_private_text(
            path,
            &serde_json::to_string(&persisted)?,
        )?;
        let _reload = self
            .reload
            .lock()
            .map_err(|_| anyhow!("model_registry_reload_lock_failed"))?;
        let mut state = self
            .state
            .write()
            .map_err(|_| anyhow!("model_registry_lock_failed"))?;
        *state = RegistryState {
            snapshot: Arc::new(next),
            // Another process can replace the file immediately after our
            // atomic write. Do not attach its metadata to our own snapshot;
            // the next request verifies the on-disk catalog once.
            signature: None,
            source: persisted.source,
            fetched_at: Some(persisted.fetched_at),
            skipped_entries: persisted.skipped_entries,
        };
        Ok(changed)
    }

    fn summary(&self, ok: bool, status: &str, error: Option<&str>) -> Value {
        let state = self
            .state
            .read()
            .unwrap_or_else(|poison| poison.into_inner());
        json!({
            "ok": ok,
            "status": if status == "ready" && state.snapshot.models.is_empty() { "empty" } else { status },
            "revision": state.snapshot.revision(),
            "modelCount": state.snapshot.models.len(),
            "providerCount": state.snapshot.provider_count,
            "source": state.source,
            "fetchedAt": state.fetched_at,
            "skippedEntries": state.skipped_entries,
            "errorCode": error,
        })
    }
}

#[cfg(test)]
thread_local! {
    static TEST_SNAPSHOT: std::cell::RefCell<Arc<RegistrySnapshot>> =
        std::cell::RefCell::new(Arc::new(RegistrySnapshot::empty()));
}

#[cfg(test)]
fn test_snapshot() -> Arc<RegistrySnapshot> {
    TEST_SNAPSHOT.with(|snapshot| Arc::clone(&snapshot.borrow()))
}

#[cfg(test)]
pub fn with_test_snapshot<T>(snapshot: RegistrySnapshot, action: impl FnOnce() -> T) -> T {
    struct Restore(Option<Arc<RegistrySnapshot>>);
    impl Drop for Restore {
        fn drop(&mut self) {
            if let Some(previous) = self.0.take() {
                TEST_SNAPSHOT.with(|snapshot| {
                    snapshot.replace(previous);
                });
            }
        }
    }
    let previous = TEST_SNAPSHOT.with(|current| current.replace(Arc::new(snapshot)));
    let _restore = Restore(Some(previous));
    action()
}

#[cfg(test)]
mod tests;
