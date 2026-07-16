use anyhow::Result;
use serde_json::Value;
use std::path::PathBuf;

#[test]
fn facade_exposes_only_stable_state_owners_and_operations() {
    let _: fn(PathBuf) -> Result<super::super::ClientStateStore> =
        super::super::ClientStateStore::new;
    let _: fn(&str) -> Result<Value> = super::super::state_get;
    let _: fn(&str, Value) -> Result<Value> = super::super::state_set;
    let _: fn(&Value) -> Result<Value> = super::super::activity_list;
    let _: fn(&Value) -> Result<Value> = super::super::snapshots_list;
    let _: fn(&str) -> Result<Value> = super::super::snapshots_restore;
}

#[test]
fn owner_types_have_no_transitive_owner_fields() {
    assert_eq!(
        std::mem::size_of::<super::super::ClientStateStore>(),
        std::mem::size_of::<PathBuf>()
    );
    assert_eq!(
        std::mem::size_of::<super::super::ActivityLog>(),
        std::mem::size_of::<PathBuf>()
    );
    assert_eq!(
        std::mem::size_of::<super::super::SnapshotStore>(),
        std::mem::size_of::<PathBuf>()
    );
}
