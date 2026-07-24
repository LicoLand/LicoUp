use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn test_store(name: &str) -> crate::platform::client_state::ClientStateStore {
    let dir = temp_test_dir(&format!("target-test-store-{}", name));
    crate::platform::client_state::ClientStateStore::new(dir).unwrap()
}

pub(super) fn temp_test_dir(name: &str) -> PathBuf {
    let dir = env::temp_dir().join(format!("lico-targets-{}-{}", name, snapshot_stamp()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn snapshot_stamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}
