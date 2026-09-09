use std::{
    collections::BTreeMap,
    num::NonZeroUsize,
    sync::atomic::{AtomicUsize, Ordering},
};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{
    policy::{HistoryKeySource, StorageMode, digest, seal_history_object},
    recovery::{
        AtomicRecoveryTarget, FreshSessionRequirement, RecoveredHistoryObject, RecoveryError,
        RetainedContentDecoder, read_authorized_history, recover_replacement_endpoint,
    },
    recovery_material::{RecoveryPackage, RecoverySecret},
    store::{
        AuthorizedHistoryStore, ContentKind, DeviceId, HistoryStoreError, InventoryPage,
        InventoryVersion, ManifestEntry, ManifestSegment, ObjectId, SegmentId,
        append_backup_segment,
    },
};

#[derive(Default)]
struct TestKeys(BTreeMap<u64, [u8; 32]>);

impl HistoryKeySource for TestKeys {
    fn key_for_generation(&self, generation: u64) -> Option<Zeroizing<[u8; 32]>> {
        self.0.get(&generation).copied().map(Zeroizing::new)
    }
}

struct PanicKeys;

impl HistoryKeySource for PanicKeys {
    fn key_for_generation(&self, _: u64) -> Option<Zeroizing<[u8; 32]>> {
        panic!("ProviderManaged reads must not consult recovery keys")
    }
}

struct JsonDecoder;

impl RetainedContentDecoder for JsonDecoder {
    fn decode_semantics(&self, _: ContentKind, bytes: &[u8]) -> Option<Value> {
        serde_json::from_slice(bytes).ok()
    }
}

#[derive(Default)]
struct TestStore {
    version: Option<InventoryVersion>,
    segments: Vec<ManifestSegment>,
    objects: BTreeMap<ObjectId, super::policy::StoredHistoryObject>,
    list_error: Option<HistoryStoreError>,
    get_error: BTreeMap<ObjectId, HistoryStoreError>,
}

impl TestStore {
    fn authorized(
        segments: Vec<ManifestSegment>,
        objects: Vec<super::policy::StoredHistoryObject>,
    ) -> Self {
        Self {
            version: Some(InventoryVersion::new("inventory-1").unwrap()),
            segments,
            objects: objects
                .into_iter()
                .map(|object| (object.header.object_id.clone(), object))
                .collect(),
            list_error: None,
            get_error: BTreeMap::new(),
        }
    }
}

impl AuthorizedHistoryStore for TestStore {
    fn list_manifest_page(
        &self,
        page_cursor: Option<&str>,
    ) -> Result<InventoryPage, HistoryStoreError> {
        if let Some(error) = &self.list_error {
            return Err(error.clone());
        }
        let cursor = page_cursor
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0);
        let segments = self
            .segments
            .get(cursor)
            .cloned()
            .into_iter()
            .collect::<Vec<_>>();
        let next_cursor = (cursor + 1 < self.segments.len()).then(|| (cursor + 1).to_string());
        Ok(InventoryPage {
            version: self.version.clone().unwrap(),
            segments,
            next_cursor,
        })
    }

    fn get_immutable(
        &self,
        object_id: &ObjectId,
        _: &InventoryVersion,
    ) -> Result<super::policy::StoredHistoryObject, HistoryStoreError> {
        if let Some(error) = self.get_error.get(object_id) {
            return Err(error.clone());
        }
        self.objects
            .get(object_id)
            .cloned()
            .ok_or(HistoryStoreError::ObjectMissing)
    }

    fn put_immutable(
        &mut self,
        object: super::policy::StoredHistoryObject,
    ) -> Result<(), HistoryStoreError> {
        match self.objects.get(&object.header.object_id) {
            Some(existing) if existing != &object => Err(HistoryStoreError::ImmutableConflict),
            Some(_) => Ok(()),
            None => {
                self.objects.insert(object.header.object_id.clone(), object);
                Ok(())
            }
        }
    }

    fn append_manifest_segment(
        &mut self,
        segment: ManifestSegment,
    ) -> Result<(), HistoryStoreError> {
        let key = (&segment.device_id, &segment.segment_id);
        match self
            .segments
            .iter()
            .find(|candidate| (&candidate.device_id, &candidate.segment_id) == key)
        {
            Some(existing) if existing != &segment => Err(HistoryStoreError::ImmutableConflict),
            Some(_) => Ok(()),
            None => {
                self.segments.push(segment);
                Ok(())
            }
        }
    }
}

#[derive(Default)]
struct TestTarget {
    reject_identity: bool,
    fail_commit: bool,
    prepare_calls: usize,
    published: BTreeMap<ObjectId, RecoveredHistoryObject>,
    session_requirement: Option<FreshSessionRequirement>,
}

impl AtomicRecoveryTarget for TestTarget {
    type PreparedIdentity = Vec<u8>;

    fn prepare_identity(&self, material: &[u8]) -> Result<Self::PreparedIdentity, RecoveryError> {
        if self.reject_identity || material != b"synthetic-authority" {
            return Err(RecoveryError::IdentityAuthorityRejected);
        }
        Ok(material.to_vec())
    }

    fn commit_atomically(
        &mut self,
        _: Self::PreparedIdentity,
        history: &BTreeMap<ObjectId, RecoveredHistoryObject>,
        fresh_sessions: FreshSessionRequirement,
    ) -> Result<(), RecoveryError> {
        self.prepare_calls += 1;
        if self.fail_commit {
            return Err(RecoveryError::AtomicCommitFailed);
        }
        self.published = history.clone();
        self.session_requirement = Some(fresh_sessions);
        Ok(())
    }
}

fn fixture_entry(id: &str, value: Value, mode: StorageMode) -> (ManifestEntry, Vec<u8>) {
    fixture_entry_for_kind(id, ContentKind::SemanticConversation, value, mode)
}

fn fixture_entry_for_kind(
    id: &str,
    content_kind: ContentKind,
    value: Value,
    mode: StorageMode,
) -> (ManifestEntry, Vec<u8>) {
    let bytes = serde_json::to_vec(&value).unwrap();
    (
        ManifestEntry {
            object_id: ObjectId::new(id).unwrap(),
            content_kind,
            storage_mode: mode,
            canonical_length: bytes.len() as u64,
            canonical_digest: digest(&bytes),
        },
        bytes,
    )
}

fn segment(device: &str, segment: &str, entries: Vec<ManifestEntry>) -> ManifestSegment {
    ManifestSegment::new(
        DeviceId::new(device).unwrap(),
        SegmentId::new(segment).unwrap(),
        entries,
    )
    .unwrap()
}

fn concurrency() -> NonZeroUsize {
    NonZeroUsize::new(3).unwrap()
}

#[test]
fn append_rejects_mismatched_object_metadata_before_publishing_a_manifest() {
    let keys = TestKeys(BTreeMap::from([(3, [33; 32])]));
    let (provider_entry, provider_bytes) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"e1"}),
        StorageMode::ProviderManaged,
    );
    let (encrypted_entry, encrypted_bytes) = fixture_entry(
        "conversation/c1/revision/e2",
        json!({"id":"c1","revision":"e2"}),
        StorageMode::ClientEncrypted { key_generation: 3 },
    );
    let provider_object = seal_history_object(&provider_entry, &provider_bytes, &keys).unwrap();
    let encrypted_object = seal_history_object(&encrypted_entry, &encrypted_bytes, &keys).unwrap();
    let manifest = segment(
        "device-a",
        "segment-1",
        vec![provider_entry.clone(), encrypted_entry.clone()],
    );

    let mut mismatched = encrypted_object.clone();
    mismatched.header.content_kind = ContentKind::SelectedArchive;
    let mut rejected_store = TestStore::authorized(vec![], vec![]);
    assert_eq!(
        append_backup_segment(
            &mut rejected_store,
            vec![provider_object.clone(), mismatched],
            manifest.clone(),
        ),
        Err(HistoryStoreError::InvalidManifest)
    );
    assert!(rejected_store.segments.is_empty());
    assert!(rejected_store.objects.is_empty());

    let mut conflicting_duplicate = provider_object.clone();
    conflicting_duplicate.body.push(b'!');
    let mut duplicate_store = TestStore::authorized(vec![], vec![]);
    assert_eq!(
        append_backup_segment(
            &mut duplicate_store,
            vec![
                provider_object.clone(),
                conflicting_duplicate,
                encrypted_object.clone(),
            ],
            manifest.clone(),
        ),
        Err(HistoryStoreError::ImmutableConflict)
    );
    assert!(duplicate_store.segments.is_empty());
    assert!(duplicate_store.objects.is_empty());

    let mut accepted_store = TestStore::authorized(vec![], vec![]);
    append_backup_segment(
        &mut accepted_store,
        vec![
            encrypted_object.clone(),
            provider_object.clone(),
            encrypted_object,
            provider_object,
        ],
        manifest.clone(),
    )
    .unwrap();
    assert_eq!(accepted_store.segments, vec![manifest]);
    assert_eq!(accepted_store.objects.len(), 2);
}

#[test]
fn provider_managed_is_default_and_reads_exact_content_without_any_key_operation() {
    assert_eq!(StorageMode::default(), StorageMode::ProviderManaged);
    let (entry, bytes) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"e1","parts":["hello"]}),
        StorageMode::default(),
    );
    let object = seal_history_object(&entry, &bytes, &PanicKeys).unwrap();
    assert_eq!(object.body, bytes);
    assert!(object.nonce.is_none());
    let store = TestStore::authorized(
        vec![segment("device-a", "segment-1", vec![entry.clone()])],
        vec![object],
    );

    let restored =
        read_authorized_history(&store, &PanicKeys, &JsonDecoder, concurrency()).unwrap();
    assert_eq!(restored.keys().collect::<Vec<_>>(), vec![&entry.object_id]);
    assert_eq!(restored[&entry.object_id].canonical_bytes, bytes);
    assert_eq!(
        restored[&entry.object_id].semantic_value,
        json!({"id":"c1","revision":"e1","parts":["hello"]})
    );
}

#[test]
fn encrypted_local_reads_and_recovery_restore_every_generation_and_retained_version() {
    let keys = TestKeys(BTreeMap::from([(1, [11; 32]), (2, [22; 32])]));
    let (first, first_bytes) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"e1","parts":["first"]}),
        StorageMode::ClientEncrypted { key_generation: 1 },
    );
    let (second, second_bytes) = fixture_entry(
        "conversation/c1/revision/e2",
        json!({"id":"c1","revision":"e2","parts":["first","second"]}),
        StorageMode::ClientEncrypted { key_generation: 2 },
    );
    let (archive, archive_bytes) = fixture_entry_for_kind(
        "archive/selected-1",
        ContentKind::SelectedArchive,
        json!({"archive":"exact-selected-bytes"}),
        StorageMode::ClientEncrypted { key_generation: 2 },
    );
    let objects = vec![
        seal_history_object(&first, &first_bytes, &keys).unwrap(),
        seal_history_object(&second, &second_bytes, &keys).unwrap(),
        seal_history_object(&archive, &archive_bytes, &keys).unwrap(),
    ];
    let store = TestStore::authorized(
        vec![
            segment(
                "device-a",
                "segment-1",
                vec![first.clone(), second.clone(), archive.clone()],
            ),
            segment("device-b", "segment-1", vec![first.clone()]),
        ],
        objects,
    );
    let manifest_bytes = serde_json::to_vec(&store.segments).unwrap();
    assert!(
        !manifest_bytes
            .windows(b"exact-selected-bytes".len())
            .any(|window| window == b"exact-selected-bytes")
    );
    let local = read_authorized_history(&store, &keys, &JsonDecoder, concurrency()).unwrap();
    assert_eq!(
        local.keys().map(ObjectId::as_str).collect::<Vec<_>>(),
        vec![
            "archive/selected-1",
            "conversation/c1/revision/e1",
            "conversation/c1/revision/e2",
        ]
    );

    let secret = RecoverySecret::from_bytes([7; 32]);
    let package = RecoveryPackage::wrap(&secret, b"synthetic-authority", &keys.0).unwrap();
    let package_bytes = serde_json::to_vec(&package).unwrap();
    for plaintext in [
        b"synthetic-authority".as_slice(),
        b"exact-selected-bytes".as_slice(),
    ] {
        assert!(
            !package_bytes
                .windows(plaintext.len())
                .any(|window| window == plaintext)
        );
    }
    let mut target = TestTarget::default();
    let recovered = recover_replacement_endpoint(
        &store,
        &package,
        &secret,
        &JsonDecoder,
        concurrency(),
        &mut target,
    )
    .unwrap();

    assert_eq!(recovered, local);
    assert_eq!(target.published, local);
    assert_eq!(
        target.session_requirement,
        Some(FreshSessionRequirement::Required)
    );
    assert_eq!(
        target.published[&first.object_id].canonical_bytes,
        first_bytes
    );
    assert_eq!(
        target.published[&second.object_id].canonical_bytes,
        second_bytes
    );
    assert_eq!(
        target.published[&first.object_id].semantic_value,
        json!({"id":"c1","revision":"e1","parts":["first"]})
    );
    assert_eq!(
        target.published[&second.object_id].semantic_value,
        json!({"id":"c1","revision":"e2","parts":["first","second"]})
    );
    assert_eq!(
        target.published[&archive.object_id].canonical_bytes,
        archive_bytes
    );
    assert_eq!(
        target.published[&archive.object_id].semantic_value,
        json!({"archive":"exact-selected-bytes"})
    );
}

#[test]
fn invalid_provider_views_and_objects_never_publish_partial_state() {
    let keys = TestKeys(BTreeMap::from([(1, [11; 32])]));
    let (entry, bytes) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"e1"}),
        StorageMode::ClientEncrypted { key_generation: 1 },
    );
    let object = seal_history_object(&entry, &bytes, &keys).unwrap();
    let secret = RecoverySecret::from_bytes([7; 32]);
    let package = RecoveryPackage::wrap(&secret, b"synthetic-authority", &keys.0).unwrap();

    let mut cases = Vec::<(TestStore, RecoveryError)>::new();
    let mut missing = TestStore::authorized(
        vec![segment("device-a", "segment-1", vec![entry.clone()])],
        vec![],
    );
    missing
        .get_error
        .insert(entry.object_id.clone(), HistoryStoreError::ObjectMissing);
    cases.push((
        missing,
        RecoveryError::HistoryIncomplete(Some(entry.object_id.clone())),
    ));

    let mut corrupt_object = object.clone();
    corrupt_object.body[0] ^= 1;
    cases.push((
        TestStore::authorized(
            vec![segment("device-a", "segment-1", vec![entry.clone()])],
            vec![corrupt_object],
        ),
        RecoveryError::CorruptObject(entry.object_id.clone()),
    ));

    let mut stale = TestStore::authorized(
        vec![segment("device-a", "segment-1", vec![entry.clone()])],
        vec![object.clone()],
    );
    stale
        .get_error
        .insert(entry.object_id.clone(), HistoryStoreError::StaleInventory);
    cases.push((stale, RecoveryError::StaleInventory));

    let mut inaccessible = TestStore::default();
    inaccessible.list_error = Some(HistoryStoreError::AccessRequired);
    cases.push((inaccessible, RecoveryError::AccessRequired));

    for (store, expected) in cases {
        let mut target = TestTarget::default();
        let error = recover_replacement_endpoint(
            &store,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut target,
        )
        .unwrap_err();
        assert_eq!(error, expected);
        assert!(target.published.is_empty());
    }
}

#[test]
fn conflicting_manifest_unknown_key_and_missing_identity_fail_without_commit() {
    let (entry, bytes) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"e1"}),
        StorageMode::ClientEncrypted { key_generation: 4 },
    );
    let available_keys = TestKeys(BTreeMap::from([(4, [44; 32])]));
    let object = seal_history_object(&entry, &bytes, &available_keys).unwrap();
    let secret = RecoverySecret::from_bytes([7; 32]);

    let missing_generation_package =
        RecoveryPackage::wrap(&secret, b"synthetic-authority", &BTreeMap::new()).unwrap();
    let store = TestStore::authorized(
        vec![segment("device-a", "segment-1", vec![entry.clone()])],
        vec![object.clone()],
    );
    let mut target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &missing_generation_package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut target,
        )
        .unwrap_err(),
        RecoveryError::UnknownKeyGeneration(4)
    );
    assert!(target.published.is_empty());

    let (conflicting, _) = fixture_entry(
        "conversation/c1/revision/e1",
        json!({"id":"c1","revision":"different"}),
        StorageMode::ClientEncrypted { key_generation: 4 },
    );
    let conflict_store = TestStore::authorized(
        vec![
            segment("device-a", "segment-1", vec![entry.clone()]),
            segment("device-b", "segment-1", vec![conflicting]),
        ],
        vec![object.clone()],
    );
    let package =
        RecoveryPackage::wrap(&secret, b"synthetic-authority", &available_keys.0).unwrap();
    let mut target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &conflict_store,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut target,
        )
        .unwrap_err(),
        RecoveryError::ConflictingObject(entry.object_id.clone())
    );
    assert!(target.published.is_empty());

    let no_identity = RecoveryPackage::synthetic_without_identity(&secret, &available_keys.0);
    let mut target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &no_identity,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut target,
        )
        .unwrap_err(),
        RecoveryError::IdentityAuthorityRequired
    );
    assert!(target.published.is_empty());
}

#[test]
fn wrong_secret_identity_rejection_and_commit_failure_leave_zero_published_state() {
    let keys = TestKeys::default();
    let (entry, bytes) = fixture_entry_for_kind(
        "snapshot/s1",
        ContentKind::ConversationSnapshot,
        json!({"snapshotId":"s1"}),
        StorageMode::ProviderManaged,
    );
    let object = seal_history_object(&entry, &bytes, &keys).unwrap();
    let store = TestStore::authorized(
        vec![segment("device-a", "segment-1", vec![entry])],
        vec![object],
    );
    let secret = RecoverySecret::from_bytes([7; 32]);
    let package = RecoveryPackage::wrap(&secret, b"synthetic-authority", &keys.0).unwrap();

    let mut wrong_secret_target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &package,
            &RecoverySecret::from_bytes([8; 32]),
            &JsonDecoder,
            concurrency(),
            &mut wrong_secret_target,
        )
        .unwrap_err(),
        RecoveryError::RecoverySecretRejected
    );
    assert!(wrong_secret_target.published.is_empty());

    let mut substituted_value = serde_json::to_value(&package).unwrap();
    let substituted = substituted_value.as_object_mut().unwrap();
    let identity = substituted.remove("identityAuthority").unwrap();
    let key_ring = substituted.remove("historyKeyRing").unwrap();
    substituted.insert("identityAuthority".to_string(), key_ring);
    substituted.insert("historyKeyRing".to_string(), identity);
    let substituted_package: RecoveryPackage = serde_json::from_value(substituted_value).unwrap();
    let mut substituted_target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &substituted_package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut substituted_target,
        )
        .unwrap_err(),
        RecoveryError::RecoverySecretRejected
    );
    assert!(substituted_target.published.is_empty());

    let mut rejected = TestTarget {
        reject_identity: true,
        ..TestTarget::default()
    };
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut rejected,
        )
        .unwrap_err(),
        RecoveryError::IdentityAuthorityRejected
    );
    assert!(rejected.published.is_empty());

    let mut failed_commit = TestTarget {
        fail_commit: true,
        ..TestTarget::default()
    };
    assert_eq!(
        recover_replacement_endpoint(
            &store,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut failed_commit,
        )
        .unwrap_err(),
        RecoveryError::AtomicCommitFailed
    );
    assert!(failed_commit.published.is_empty());
}

#[test]
fn provider_access_and_identity_authority_are_independent_prerequisites() {
    static KEY_CALLS: AtomicUsize = AtomicUsize::new(0);
    struct CountingKeys;
    impl HistoryKeySource for CountingKeys {
        fn key_for_generation(&self, _: u64) -> Option<Zeroizing<[u8; 32]>> {
            KEY_CALLS.fetch_add(1, Ordering::SeqCst);
            None
        }
    }

    let mut inaccessible = TestStore::default();
    inaccessible.list_error = Some(HistoryStoreError::AccessRequired);
    let secret = RecoverySecret::from_bytes([7; 32]);
    let package = RecoveryPackage::wrap(&secret, b"synthetic-authority", &BTreeMap::new()).unwrap();
    let mut target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &inaccessible,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut target,
        )
        .unwrap_err(),
        RecoveryError::AccessRequired
    );
    assert_eq!(KEY_CALLS.load(Ordering::SeqCst), 0);
    assert!(target.published.is_empty());

    let empty = TestStore::authorized(vec![], vec![]);
    let mut empty_target = TestTarget::default();
    assert_eq!(
        recover_replacement_endpoint(
            &empty,
            &package,
            &secret,
            &JsonDecoder,
            concurrency(),
            &mut empty_target,
        )
        .unwrap_err(),
        RecoveryError::HistoryIncomplete(None)
    );
    assert!(empty_target.published.is_empty());

    let _ = CountingKeys;
}
