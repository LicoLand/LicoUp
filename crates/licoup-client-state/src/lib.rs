//! The single authority for LicoUp's portable client-state persistence and the
//! resource policy that bounds it.
//!
//! `ClientStateStore` owns the bounded, privately written collection documents
//! under the portable data root; `ActivityLog` owns the bounded activity
//! journal; `SnapshotStore` owns capture, redaction and restore; and
//! `ClientResourcePolicy` owns every limit those three obey. Nothing here
//! reaches upward: a domain, a command handler or a wire contract stays above
//! this crate, so every layer that stores client state depends on this one
//! instead of on the layer that serves requests.
//!
//! `collections` is the collection-document owner, `activity` and `snapshots`
//! are the two journal owners on top of it, `serialization`, `redaction` and
//! `paths` are its private write, redaction and location rules, `policy` holds
//! the schema version and every bound, `migration` is the only module allowed
//! to adopt an older collection document, `accessors` derives the journal
//! owners from a store, and `resource_bounds` admits history pages, search
//! pages, archive workers and reservations within those bounds.

mod accessors;
mod activity;
mod collections;
mod migration;
mod paths;
mod policy;
mod redaction;
mod resource_policy;
mod serialization;
mod snapshots;

// A public module of its own: its `ClientResourcePolicy` admits work under the
// bounds this crate re-exports at the root, so callers reach it by module path.
pub mod resource_bounds;

pub use activity::ActivityLog;
pub use collections::{
    ClientStateStore, TARGET_DISCOVERY_CACHE_COLLECTION, TARGET_DISCOVERY_CACHE_SCHEMA,
    TargetRouteRecord,
};
pub use migration::{migrate_collections, probe_collections};
pub use resource_policy::{ClientResourceBounds, ClientResourcePolicy};
pub use snapshots::{SnapshotRecord, SnapshotStore};

#[cfg(test)]
mod tests;
