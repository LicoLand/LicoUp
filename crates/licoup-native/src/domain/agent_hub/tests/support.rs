use crate::platform::client_state::ClientStateStore;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn test_store(name: &str) -> ClientStateStore {
    ClientStateStore::new(temp_dir(&format!("store-{name}"))).unwrap()
}

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let dir = env::temp_dir().join(format!(
        "lico-agent-hub-{}-{}-{}",
        name,
        now.as_secs(),
        now.subsec_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

pub(super) fn portable_params(name: &str) -> (PathBuf, serde_json::Value) {
    let dir = temp_dir(name);
    let params = serde_json::json!({
        "portableDir": dir.to_string_lossy(),
        "platformCapabilities": {
            "os": "macos",
            "architecture": "aarch64",
            "managers": ["homebrew", "npm"],
            "scanGeneration": 7
        },
        "discoveryCandidates": []
    });
    (dir, params)
}
