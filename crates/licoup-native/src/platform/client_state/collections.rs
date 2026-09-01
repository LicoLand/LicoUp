use crate::platform::file_security::{ensure_private_dir, open_private_lock_file};
use anyhow::{Result, anyhow, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::SystemTime;

use super::{paths, policy, serialization};

pub(crate) const TARGET_DISCOVERY_CACHE_COLLECTION: &str = "target-discovery-cache";
pub(crate) const TARGET_DISCOVERY_CACHE_SCHEMA: &str = "licoup.target-discovery-cache.v1";
const TARGET_DISCOVERY_CACHE_LOCK: &str = ".target-discovery-cache.lock";

/// Typed internal projection of one target-discovery-cache record. Only
/// identity and resolution fields are decoded; unknown JSON extension fields
/// round-trip through the persisted document without a second authority.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetRouteRecord {
    pub(crate) schema_version: String,
    pub(crate) target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) binary_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) config_path: Option<String>,
    pub(crate) scan_source: String,
    pub(crate) runtime_ready: bool,
    pub(crate) cached_at_epoch_seconds: u64,
    #[serde(flatten)]
    pub(crate) extension: Map<String, Value>,
}

#[derive(Clone, Debug)]
pub struct ClientStateStore {
    root: PathBuf,
    target_index: Arc<TargetCollectionIndex>,
}

#[derive(Debug, Default)]
struct TargetCollectionIndex {
    state: RwLock<Option<IndexedTargetCollection>>,
}

/// Cross-process transaction boundary for every target-route mutation.
/// Atomic file replacement protects readers; this guard additionally keeps a
/// read-modify-write update indivisible across independent store instances.
struct TargetRouteTransactionGuard {
    lock: File,
}

impl TargetRouteTransactionGuard {
    fn acquire(root: &Path) -> Result<Self> {
        let lock = open_private_lock_file(&root.join(TARGET_DISCOVERY_CACHE_LOCK))?;
        lock.lock_exclusive()
            .map_err(|_| anyhow!("target_route_transaction_lock_unavailable"))?;
        Ok(Self { lock })
    }
}

impl Drop for TargetRouteTransactionGuard {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.lock);
    }
}

#[derive(Debug)]
struct IndexedTargetCollection {
    generation: Option<FileGeneration>,
    parses: u64,
    invalidations: u64,
    records: Vec<TargetRouteRecord>,
    by_target: HashMap<String, usize>,
    document: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FileGeneration {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    len: u64,
    modified: SystemTime,
}

impl ClientStateStore {
    pub fn portable() -> Result<Self> {
        Self::new(paths::portable_state_root()?)
    }

    pub(crate) fn portable_read_only() -> Result<Self> {
        Ok(Self::open_read_only(paths::portable_state_root_read_only()?))
    }

    /// Open a read-only projection without creating directories, collection
    /// files, snapshots, or activity state. Missing collections read empty.
    pub(crate) fn open_read_only(root: PathBuf) -> Self {
        Self {
            root,
            target_index: Arc::new(TargetCollectionIndex::default()),
        }
    }

    pub fn new(root: PathBuf) -> Result<Self> {
        ensure_private_dir(&root)?;
        ensure_private_dir(&paths::snapshot_root(&root))?;
        ensure_private_dir(&paths::activity_root(&root))?;
        let store = Self {
            root,
            target_index: Arc::new(TargetCollectionIndex::default()),
        };
        store.ensure_collections()?;
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn collection_path(&self, collection: &str) -> Result<PathBuf> {
        validate_collection(collection)?;
        Ok(paths::collection_path(&self.root, collection))
    }

    pub fn read_collection(&self, collection: &str) -> Result<Value> {
        let path = self.collection_path(collection)?;
        serialization::read_json_or_default(&path, policy::MAX_COLLECTION_DOCUMENT_BYTES, || {
            empty_collection(collection)
        })
    }

    pub(crate) fn read_collection_read_only(&self, collection: &str) -> Result<Value> {
        let path = self.collection_path(collection)?;
        serialization::read_json_or_default_read_only(
            &path,
            policy::MAX_COLLECTION_DOCUMENT_BYTES,
            || empty_collection(collection),
        )
    }

    pub fn write_collection(&self, collection: &str, value: Value) -> Result<Value> {
        let path = self.collection_path(collection)?;
        let document = normalize_collection(collection, value);
        let _target_transaction = if collection == TARGET_DISCOVERY_CACHE_COLLECTION {
            Some(TargetRouteTransactionGuard::acquire(&self.root)?)
        } else {
            None
        };
        serialization::atomic_write_json(&path, &document, policy::MAX_COLLECTION_DOCUMENT_BYTES)?;
        Ok(document)
    }

    /// Typed target-route read in document order. The projection is refreshed
    /// only when the persisted file generation changes, so repeated reads
    /// decode the collection exactly once per generation.
    #[cfg(test)]
    pub(crate) fn read_target_routes(&self) -> Result<Vec<TargetRouteRecord>> {
        let path = self.collection_path(TARGET_DISCOVERY_CACHE_COLLECTION)?;
        let mut guard = lock_target_index(&self.target_index);
        refresh_target_index_locked(&mut guard, &path)?;
        let cached = guard
            .as_ref()
            .ok_or_else(|| anyhow!("target index projection is unavailable"))?;
        Ok(cached.records.clone())
    }

    /// Keyed target-route lookup over the store-owned projection. A changed
    /// file identity, size, modification time, or generation forces one
    /// reparse before the lookup; no linear scan or per-call reconstruction
    /// remains.
    pub(crate) fn target_route(&self, target: &str) -> Result<Option<TargetRouteRecord>> {
        let path = self.collection_path(TARGET_DISCOVERY_CACHE_COLLECTION)?;
        let generation = file_generation(&path);
        {
            let guard = read_target_index(&self.target_index);
            if let Some(cached) = guard.as_ref()
                && cached.generation == generation
            {
                return Ok(cached
                    .by_target
                    .get(target)
                    .map(|&position| cached.records[position].clone()));
            }
        }
        let mut guard = lock_target_index(&self.target_index);
        refresh_target_index_locked(&mut guard, &path)?;
        let cached = guard
            .as_ref()
            .ok_or_else(|| anyhow!("target index projection is unavailable"))?;
        Ok(cached
            .by_target
            .get(target)
            .map(|&position| cached.records[position].clone()))
    }

    /// Transactional replacement of all typed target routes. The document
    /// keeps every unknown top-level and record extension field, is persisted
    /// with the private atomic writer, and only then swaps the projection.
    pub(crate) fn write_target_routes(&self, records: &[TargetRouteRecord]) -> Result<()> {
        let _transaction = TargetRouteTransactionGuard::acquire(&self.root)?;
        let path = self.collection_path(TARGET_DISCOVERY_CACHE_COLLECTION)?;
        let mut guard = lock_target_index(&self.target_index);
        refresh_target_index_locked(&mut guard, &path)?;
        write_target_routes_locked(&path, &mut guard, records)
    }

    /// Transactional read-modify-write over the latest persisted route set.
    /// The callback runs while the cross-process lock is held, so no selected
    /// scan can overwrite routes committed by another concurrent scan.
    pub(crate) fn update_target_routes<F>(&self, update: F) -> Result<()>
    where
        F: FnOnce(&mut Vec<TargetRouteRecord>) -> Result<()>,
    {
        let _transaction = TargetRouteTransactionGuard::acquire(&self.root)?;
        let path = self.collection_path(TARGET_DISCOVERY_CACHE_COLLECTION)?;
        let mut guard = lock_target_index(&self.target_index);
        refresh_target_index_locked(&mut guard, &path)?;
        let mut records = guard
            .as_ref()
            .ok_or_else(|| anyhow!("target index projection is unavailable"))?
            .records
            .clone();
        update(&mut records)?;
        write_target_routes_locked(&path, &mut guard, &records)
    }

    #[cfg(test)]
    pub(crate) fn target_index_parse_count(&self) -> u64 {
        let guard = read_target_index(&self.target_index);
        guard.as_ref().map_or(0, |cached| cached.parses)
    }

    #[cfg(test)]
    pub(crate) fn target_index_invalidation_count(&self) -> u64 {
        let guard = read_target_index(&self.target_index);
        guard.as_ref().map_or(0, |cached| cached.invalidations)
    }

    fn ensure_collections(&self) -> Result<()> {
        for collection in policy::COLLECTIONS {
            let path = self.collection_path(collection)?;
            if path.try_exists()? {
                continue;
            }
            if *collection == TARGET_DISCOVERY_CACHE_COLLECTION {
                let _transaction = TargetRouteTransactionGuard::acquire(&self.root)?;
                if !path.try_exists()? {
                    serialization::atomic_write_json(
                        &path,
                        &empty_collection(collection),
                        policy::MAX_COLLECTION_DOCUMENT_BYTES,
                    )?;
                }
                continue;
            }
            serialization::atomic_write_json(
                &path,
                &empty_collection(collection),
                policy::MAX_COLLECTION_DOCUMENT_BYTES,
            )?;
        }
        Ok(())
    }
}

fn write_target_routes_locked(
    path: &Path,
    index: &mut Option<IndexedTargetCollection>,
    records: &[TargetRouteRecord],
) -> Result<()> {
    let (mut document, parses, invalidations) = {
        let cached = index
            .as_ref()
            .ok_or_else(|| anyhow!("target index projection is unavailable"))?;
        (cached.document.clone(), cached.parses, cached.invalidations)
    };
    document["items"] = serde_json::to_value(records)?;
    serialization::atomic_write_json(path, &document, policy::MAX_COLLECTION_DOCUMENT_BYTES)?;
    *index = Some(IndexedTargetCollection {
        generation: file_generation(path),
        parses,
        invalidations,
        records: records.to_vec(),
        by_target: index_target_routes(records),
        document,
    });
    Ok(())
}

fn read_target_index(
    index: &TargetCollectionIndex,
) -> std::sync::RwLockReadGuard<'_, Option<IndexedTargetCollection>> {
    index
        .state
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock_target_index(
    index: &TargetCollectionIndex,
) -> std::sync::RwLockWriteGuard<'_, Option<IndexedTargetCollection>> {
    index
        .state
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn refresh_target_index_locked(
    index: &mut Option<IndexedTargetCollection>,
    path: &Path,
) -> Result<()> {
    let generation = file_generation(path);
    if let Some(cached) = index.as_ref()
        && cached.generation == generation
    {
        return Ok(());
    }
    let document =
        serialization::read_json_or_default(path, policy::MAX_COLLECTION_DOCUMENT_BYTES, || {
            empty_collection(TARGET_DISCOVERY_CACHE_COLLECTION)
        })?;
    let routes = decode_target_routes(&document)?;
    let prior = index.take();
    let parses = prior.as_ref().map_or(0, |cached| cached.parses) + 1;
    let invalidations =
        prior.as_ref().map_or(0, |cached| cached.invalidations) + u64::from(prior.is_some());
    let by_target = index_target_routes(&routes);
    *index = Some(IndexedTargetCollection {
        generation,
        parses,
        invalidations,
        records: routes,
        by_target,
        document,
    });
    Ok(())
}

fn index_target_routes(records: &[TargetRouteRecord]) -> HashMap<String, usize> {
    let mut by_target = HashMap::with_capacity(records.len());
    for (position, record) in records.iter().enumerate() {
        // Preserve the legacy document-order lookup if a malformed external
        // writer supplies duplicate identities. The typed index accelerates
        // lookup without silently changing which record wins.
        by_target.entry(record.target.clone()).or_insert(position);
    }
    by_target
}

fn file_generation(path: &Path) -> Option<FileGeneration> {
    let metadata = fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(FileGeneration {
            device: metadata.dev(),
            inode: metadata.ino(),
            len: metadata.len(),
            modified: metadata.modified().ok()?,
        })
    }
    #[cfg(not(unix))]
    {
        Some(FileGeneration {
            len: metadata.len(),
            modified: metadata.modified().ok()?,
        })
    }
}

fn decode_target_routes(document: &Value) -> Result<Vec<TargetRouteRecord>> {
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    items
        .into_iter()
        .map(|item| {
            let record: TargetRouteRecord = serde_json::from_value(item)?;
            ensure!(
                record.schema_version == TARGET_DISCOVERY_CACHE_SCHEMA,
                "target discovery cache schema is invalid"
            );
            Ok(record)
        })
        .collect()
}

pub(super) fn validate_collection(collection: &str) -> Result<()> {
    if policy::COLLECTIONS.contains(&collection) {
        Ok(())
    } else {
        Err(anyhow!("unsupported client state collection"))
    }
}

fn empty_collection(collection: &str) -> Value {
    json!({
        "schemaVersion": policy::STATE_SCHEMA_VERSION,
        "collection": collection,
        "items": []
    })
}

fn normalize_collection(collection: &str, value: Value) -> Value {
    if value.is_object() {
        let mut object = value.as_object().cloned().unwrap_or_default();
        object
            .entry("schemaVersion".to_string())
            .or_insert_with(|| json!(policy::STATE_SCHEMA_VERSION));
        object
            .entry("collection".to_string())
            .or_insert_with(|| json!(collection));
        Value::Object(object)
    } else {
        json!({
            "schemaVersion": policy::STATE_SCHEMA_VERSION,
            "collection": collection,
            "items": value
        })
    }
}
