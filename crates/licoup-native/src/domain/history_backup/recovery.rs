use std::{collections::BTreeMap, num::NonZeroUsize, sync::Mutex, thread};

use serde_json::Value;
use thiserror::Error;

use super::{
    policy::{HistoryKeySource, ObjectOpenError, StorageMode, open_history_object},
    recovery_material::{RecoveryMaterialError, RecoveryPackage, RecoverySecret},
    store::{
        AuthorizedHistoryStore, ContentKind, HistoryStoreError, ManifestEntry, ObjectId,
        freeze_inventory,
    },
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveredHistoryObject {
    pub content_kind: ContentKind,
    pub storage_mode: StorageMode,
    pub canonical_bytes: Vec<u8>,
    pub semantic_value: Value,
}

pub trait RetainedContentDecoder: Sync {
    fn decode_semantics(&self, kind: ContentKind, canonical_bytes: &[u8]) -> Option<Value>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FreshSessionRequirement {
    Required,
}

/// Caller-owned bridge to the pinned LicoArc authority implementation and its
/// durable transaction. Preparing identity must not publish live state and is
/// responsible for deriving fresh replacement-Endpoint keys.
pub trait AtomicRecoveryTarget {
    type PreparedIdentity;

    fn prepare_identity(
        &self,
        protected_authority_material: &[u8],
    ) -> Result<Self::PreparedIdentity, RecoveryError>;

    fn commit_atomically(
        &mut self,
        prepared_identity: Self::PreparedIdentity,
        complete_history: &BTreeMap<ObjectId, RecoveredHistoryObject>,
        fresh_sessions: FreshSessionRequirement,
    ) -> Result<(), RecoveryError>;
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RecoveryError {
    #[error("provider access is required")]
    AccessRequired,
    #[error("retained history is incomplete")]
    HistoryIncomplete(Option<ObjectId>),
    #[error("retained history is corrupt")]
    CorruptObject(ObjectId),
    #[error("retained history has conflicting immutable content")]
    ConflictingObject(ObjectId),
    #[error("the frozen provider inventory became stale")]
    StaleInventory,
    #[error("an encrypted history key generation is unavailable")]
    UnknownKeyGeneration(u64),
    #[error("identity recovery authority is required")]
    IdentityAuthorityRequired,
    #[error("recovery secret was rejected")]
    RecoverySecretRejected,
    #[error("identity recovery authority rejected the transition")]
    IdentityAuthorityRejected,
    #[error("atomic recovery commit failed")]
    AtomicCommitFailed,
    #[error("provider operation failed")]
    ProviderFailure,
    #[error("history manifest is invalid")]
    InvalidManifest,
}

pub fn read_authorized_history<S, K, D>(
    store: &S,
    local_keys: &K,
    decoder: &D,
    max_concurrency: NonZeroUsize,
) -> Result<BTreeMap<ObjectId, RecoveredHistoryObject>, RecoveryError>
where
    S: AuthorizedHistoryStore,
    K: HistoryKeySource,
    D: RetainedContentDecoder,
{
    let (version, inventory) = freeze_inventory(store).map_err(map_inventory_error)?;
    load_complete_history(
        store,
        &version,
        &inventory,
        local_keys,
        decoder,
        max_concurrency,
    )
}

pub fn recover_replacement_endpoint<S, D, T>(
    store: &S,
    package: &RecoveryPackage,
    secret: &RecoverySecret,
    decoder: &D,
    max_concurrency: NonZeroUsize,
    target: &mut T,
) -> Result<BTreeMap<ObjectId, RecoveredHistoryObject>, RecoveryError>
where
    S: AuthorizedHistoryStore,
    D: RetainedContentDecoder,
    T: AtomicRecoveryTarget,
{
    // Provider authorization and a frozen inventory are prerequisites. Key
    // possession must never turn an inaccessible provider into an empty success.
    let (version, inventory) = freeze_inventory(store).map_err(map_inventory_error)?;
    if inventory.is_empty() {
        return Err(RecoveryError::HistoryIncomplete(None));
    }
    let material = package.open(secret).map_err(map_material_error)?;
    let prepared_identity = target.prepare_identity(&material.identity_authority)?;
    let staged = load_complete_history(
        store,
        &version,
        &inventory,
        &material,
        decoder,
        max_concurrency,
    )?;
    target.commit_atomically(
        prepared_identity,
        &staged,
        FreshSessionRequirement::Required,
    )?;
    Ok(staged)
}

fn load_complete_history<S, K, D>(
    store: &S,
    version: &super::store::InventoryVersion,
    inventory: &BTreeMap<ObjectId, ManifestEntry>,
    keys: &K,
    decoder: &D,
    max_concurrency: NonZeroUsize,
) -> Result<BTreeMap<ObjectId, RecoveredHistoryObject>, RecoveryError>
where
    S: AuthorizedHistoryStore,
    K: HistoryKeySource,
    D: RetainedContentDecoder,
{
    if let Some(generation) = inventory
        .values()
        .find_map(|entry| match entry.storage_mode {
            StorageMode::ProviderManaged => None,
            StorageMode::ClientEncrypted { key_generation }
                if keys.key_for_generation(key_generation).is_none() =>
            {
                Some(key_generation)
            }
            StorageMode::ClientEncrypted { .. } => None,
        })
    {
        return Err(RecoveryError::UnknownKeyGeneration(generation));
    }

    let entries = inventory.values().collect::<Vec<_>>();
    let output = Mutex::new(BTreeMap::<ObjectId, RecoveredHistoryObject>::new());
    let failure = Mutex::new(None::<RecoveryError>);
    let workers = max_concurrency.get().min(entries.len().max(1));
    let chunk_size = entries.len().div_ceil(workers).max(1);

    thread::scope(|scope| {
        for chunk in entries.chunks(chunk_size) {
            let output = &output;
            let failure = &failure;
            scope.spawn(move || {
                for entry in chunk {
                    if failure.lock().expect("failure lock").is_some() {
                        return;
                    }
                    let result = load_one(store, version, entry, keys, decoder);
                    match result {
                        Ok(restored) => {
                            output
                                .lock()
                                .expect("restore output lock")
                                .insert(entry.object_id.clone(), restored);
                        }
                        Err(error) => {
                            let mut first = failure.lock().expect("failure lock");
                            if first.is_none() {
                                *first = Some(error);
                            }
                            return;
                        }
                    }
                }
            });
        }
    });

    if let Some(error) = failure.into_inner().expect("failure lock") {
        return Err(error);
    }
    let restored = output.into_inner().expect("restore output lock");
    if restored.len() != inventory.len() {
        return Err(RecoveryError::InvalidManifest);
    }
    Ok(restored)
}

fn load_one<S, K, D>(
    store: &S,
    version: &super::store::InventoryVersion,
    entry: &ManifestEntry,
    keys: &K,
    decoder: &D,
) -> Result<RecoveredHistoryObject, RecoveryError>
where
    S: AuthorizedHistoryStore,
    K: HistoryKeySource,
    D: RetainedContentDecoder,
{
    let object = store
        .get_immutable(&entry.object_id, version)
        .map_err(|error| map_object_store_error(error, &entry.object_id))?;
    let canonical_bytes =
        open_history_object(entry, &object, keys).map_err(|error| match error {
            ObjectOpenError::MissingKey(generation) => {
                RecoveryError::UnknownKeyGeneration(generation)
            }
            ObjectOpenError::HeaderMismatch
            | ObjectOpenError::AuthenticationFailed
            | ObjectOpenError::ContentCorrupt => {
                RecoveryError::CorruptObject(entry.object_id.clone())
            }
        })?;
    let semantic_value = decoder
        .decode_semantics(entry.content_kind, &canonical_bytes)
        .ok_or_else(|| RecoveryError::CorruptObject(entry.object_id.clone()))?;
    Ok(RecoveredHistoryObject {
        content_kind: entry.content_kind,
        storage_mode: entry.storage_mode,
        canonical_bytes,
        semantic_value,
    })
}

fn map_inventory_error(error: HistoryStoreError) -> RecoveryError {
    match error {
        HistoryStoreError::AccessRequired => RecoveryError::AccessRequired,
        HistoryStoreError::StaleInventory => RecoveryError::StaleInventory,
        HistoryStoreError::ObjectMissing => RecoveryError::InvalidManifest,
        HistoryStoreError::ImmutableConflict => {
            // Inventory conflicts are rejected before any object is loaded.
            RecoveryError::InvalidManifest
        }
        HistoryStoreError::ManifestConflict(object_id) => {
            RecoveryError::ConflictingObject(object_id)
        }
        HistoryStoreError::InvalidManifest => RecoveryError::InvalidManifest,
        HistoryStoreError::ProviderFailure => RecoveryError::ProviderFailure,
    }
}

fn map_object_store_error(error: HistoryStoreError, object_id: &ObjectId) -> RecoveryError {
    match error {
        HistoryStoreError::AccessRequired => RecoveryError::AccessRequired,
        HistoryStoreError::StaleInventory => RecoveryError::StaleInventory,
        HistoryStoreError::ObjectMissing => {
            RecoveryError::HistoryIncomplete(Some(object_id.clone()))
        }
        HistoryStoreError::ImmutableConflict => RecoveryError::ConflictingObject(object_id.clone()),
        HistoryStoreError::ManifestConflict(conflicting_id) => {
            RecoveryError::ConflictingObject(conflicting_id)
        }
        HistoryStoreError::InvalidManifest => RecoveryError::InvalidManifest,
        HistoryStoreError::ProviderFailure => RecoveryError::ProviderFailure,
    }
}

fn map_material_error(error: RecoveryMaterialError) -> RecoveryError {
    match error {
        RecoveryMaterialError::IdentityAuthorityRequired => {
            RecoveryError::IdentityAuthorityRequired
        }
        RecoveryMaterialError::InvalidPackage | RecoveryMaterialError::SecretRejected => {
            RecoveryError::RecoverySecretRejected
        }
    }
}
