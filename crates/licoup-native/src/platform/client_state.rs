mod accessors;
mod activity;
mod collections;
mod operations;
mod paths;
mod policy;
mod redaction;
mod serialization;
mod snapshots;

pub use activity::ActivityLog;
pub use collections::ClientStateStore;
#[cfg(test)]
pub(crate) use collections::TARGET_DISCOVERY_CACHE_COLLECTION;
pub(crate) use collections::{TARGET_DISCOVERY_CACHE_SCHEMA, TargetRouteRecord};
pub use operations::{activity_list, snapshots_list, snapshots_restore, state_get, state_set};
pub use snapshots::{SnapshotRecord, SnapshotStore};

#[cfg(test)]
mod tests;
