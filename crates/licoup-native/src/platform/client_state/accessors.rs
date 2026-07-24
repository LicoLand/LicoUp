use super::activity::ActivityLog;
use super::collections::ClientStateStore;
use super::snapshots::SnapshotStore;

impl ClientStateStore {
    pub fn activity_log(&self) -> ActivityLog {
        ActivityLog::from_state_root(self.root())
    }

    pub fn snapshot_store(&self) -> SnapshotStore {
        SnapshotStore::from_state_root(self.root())
    }
}
