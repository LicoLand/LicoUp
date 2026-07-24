use super::super::artifact::runtime_artifact_digest;
use super::super::params::timestamp;
use std::fs;

#[test]
fn runtime_artifact_digest_tracks_the_opened_file_identity_and_content() {
    let root = std::env::temp_dir().join(format!(
        "lico-runtime-artifact-{}-{}",
        std::process::id(),
        timestamp()
    ));
    fs::create_dir_all(&root).unwrap();
    let executable = root.join("runtime-canary");
    fs::write(&executable, b"accepted-runtime").unwrap();
    let first = runtime_artifact_digest(&executable).unwrap();
    fs::write(&executable, b"different-runtime").unwrap();
    let second = runtime_artifact_digest(&executable).unwrap();
    let _ = fs::remove_dir_all(root);

    assert!(first.starts_with("sha256:"));
    assert_ne!(first, second);
}
