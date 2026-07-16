use serde_json::json;

use super::support::{PortableDataDirOverrideGuard, TestRoot};

#[test]
fn first_portable_launch_creates_only_fresh_canonical_state() {
    let root = TestRoot::new("portable");
    let portable_root = root.path().join("portable-data");
    let _override = PortableDataDirOverrideGuard::set(portable_root.clone());

    let store = super::super::ClientStateStore::portable().unwrap();

    assert_eq!(
        store.root(),
        portable_root.join(super::super::policy::CLIENT_STATE_DIR)
    );
    assert!(
        store
            .root()
            .join(super::super::policy::SNAPSHOT_DIR)
            .is_dir()
    );
    assert!(
        store
            .root()
            .join(super::super::policy::ACTIVITY_DIR)
            .is_dir()
    );
    for collection in super::super::policy::COLLECTIONS {
        assert_eq!(
            store.read_collection(collection).unwrap()["items"],
            json!([])
        );
    }
}

#[test]
fn collections_normalize_objects_and_scalar_item_lists_independently() {
    let root = TestRoot::new("collections");
    let store = super::super::ClientStateStore::new(root.path().join("state")).unwrap();

    let object = store
        .write_collection("settings", json!({"items": [{"key": "theme"}]}))
        .unwrap();
    let scalar = store
        .write_collection("targets", json!([{"target": "opencode"}]))
        .unwrap();

    assert_eq!(object["collection"], "settings");
    assert_eq!(scalar["collection"], "targets");
    assert_eq!(scalar["items"][0]["target"], "opencode");
    assert!(store.read_collection("unsupported-collection").is_err());
}
