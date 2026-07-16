use crate::platform::file_security::ensure_private_dir;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

use super::{paths, policy, serialization};

#[derive(Clone, Debug)]
pub struct ClientStateStore {
    root: PathBuf,
}

impl ClientStateStore {
    pub fn portable() -> Result<Self> {
        Self::new(paths::portable_state_root()?)
    }

    pub fn new(root: PathBuf) -> Result<Self> {
        ensure_private_dir(&root)?;
        ensure_private_dir(&paths::snapshot_root(&root))?;
        ensure_private_dir(&paths::activity_root(&root))?;
        let store = Self { root };
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

    pub fn write_collection(&self, collection: &str, value: Value) -> Result<Value> {
        let path = self.collection_path(collection)?;
        let document = normalize_collection(collection, value);
        serialization::atomic_write_json(&path, &document, policy::MAX_COLLECTION_DOCUMENT_BYTES)?;
        Ok(document)
    }

    fn ensure_collections(&self) -> Result<()> {
        for collection in policy::COLLECTIONS {
            let path = self.collection_path(collection)?;
            if !path.try_exists()? {
                serialization::atomic_write_json(
                    &path,
                    &empty_collection(collection),
                    policy::MAX_COLLECTION_DOCUMENT_BYTES,
                )?;
            }
        }
        Ok(())
    }
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
