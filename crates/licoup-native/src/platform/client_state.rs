// The generic local persistence owner now lives in `licoup-client-state`. It is
// re-exported here at its former paths and its former visibility, so this
// extraction changes no caller inside or outside the crate. What stays is the
// command surface: `operations` is the only module in this directory that
// depends on the generated wire contract.
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use licoup_client_state::TARGET_DISCOVERY_CACHE_COLLECTION;
pub use licoup_client_state::{
    ActivityLog, ClientStateStore, SnapshotRecord, SnapshotStore, migrate_collections,
    probe_collections,
};
// The target discovery cache names its schema, its collection and its route
// record at these former paths. The cache itself moved to
// `licoup-agent-targets` and reads `licoup-client-state` directly, so no
// caller in this crate reaches them today; the re-export stays while the crate
// split is in flight, because a later Node's tree may still name the old path.
#[allow(unused_imports)]
pub(crate) use licoup_client_state::{TARGET_DISCOVERY_CACHE_SCHEMA, TargetRouteRecord};

mod operations;
pub use operations::{activity_list, snapshots_list, snapshots_restore, state_get, state_set};

#[cfg(test)]
mod tests;
