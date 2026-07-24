use super::super::*;
use super::support::*;

#[test]
fn skill_install_rollback_rejects_snapshot_id_traversal() {
    let (store, _install_root, _installed) = installed_test_skill("rollback-id", "codex");

    let result = skill_install_rollback_in(
        &store,
        &json!({"agent": "codex", "snapshotId": "../outside"}),
    );

    assert!(result.is_err());
}

#[test]
fn skill_install_rollback_rejects_cross_agent_snapshot_ownership() {
    let (store, install_root, installed) = installed_test_skill("rollback-owner", "codex");
    pair_request_in(
        &store,
        &json!({"agent": "claude-code", "target": "claude-code"}),
    )
    .unwrap();
    pair_approve_in(&store, &json!({"agent": "claude-code"})).unwrap();

    let result = skill_install_rollback_in(
        &store,
        &json!({
            "agent": "claude-code",
            "snapshotId": installed["rollbackSnapshotId"].as_str().unwrap()
        }),
    );

    assert!(result.is_err());
    assert!(install_root.join("review-helper").is_dir());
}

#[test]
fn skill_install_rollback_requires_current_pairing_approval() {
    let (store, install_root, installed) = installed_test_skill("rollback-approval", "codex");
    pair_revoke_in(&store, &json!({"agent": "codex"})).unwrap();

    let result = skill_install_rollback_in(
        &store,
        &json!({
            "agent": "codex",
            "snapshotId": installed["rollbackSnapshotId"].as_str().unwrap()
        }),
    );

    assert!(result.is_err());
    assert!(install_root.join("review-helper").is_dir());
}

#[test]
fn skill_install_rollback_rejects_tampered_absolute_target() {
    let (store, install_root, installed) = installed_test_skill("rollback-contained", "codex");
    let snapshot_id = installed["rollbackSnapshotId"].as_str().unwrap();
    let snapshot_path = store
        .root()
        .join("snapshots")
        .join(format!("{snapshot_id}.json"));
    let mut snapshot: Value =
        serde_json::from_str(&fs::read_to_string(&snapshot_path).unwrap()).unwrap();
    let external = temp_test_dir("rollback-external");
    fs::write(external.join("sentinel"), "preserve").unwrap();
    snapshot["installDir"] = json!(display_path(external.clone()));
    crate::platform::file_security::atomic_write_private_text(
        &snapshot_path,
        &format!("{}\n", serde_json::to_string(&snapshot).unwrap()),
    )
    .unwrap();

    let result = skill_install_rollback_in(
        &store,
        &json!({"agent": "codex", "snapshotId": snapshot_id}),
    );

    assert!(result.is_err());
    assert_eq!(
        fs::read_to_string(external.join("sentinel")).unwrap(),
        "preserve"
    );
    assert!(install_root.join("review-helper").is_dir());
}

#[test]
fn skill_install_rollback_is_single_use() {
    let (store, install_root, installed) = installed_test_skill("rollback-replay", "codex");
    let snapshot_id = installed["rollbackSnapshotId"].as_str().unwrap();

    skill_install_rollback_in(
        &store,
        &json!({"agent": "codex", "snapshotId": snapshot_id}),
    )
    .unwrap();
    let replay = skill_install_rollback_in(
        &store,
        &json!({"agent": "codex", "snapshotId": snapshot_id}),
    );

    assert!(replay.is_err());
    assert!(!install_root.join("review-helper").exists());
}

#[cfg(unix)]
#[test]
fn skill_install_rollback_rejects_symlink_target_without_touching_referent() {
    use std::os::unix::fs::symlink;

    let (store, install_root, installed) = installed_test_skill("rollback-symlink", "codex");
    let install_dir = install_root.join("review-helper");
    fs::remove_dir_all(&install_dir).unwrap();
    let external = temp_test_dir("rollback-symlink-external");
    fs::write(external.join("sentinel"), "preserve").unwrap();
    symlink(&external, &install_dir).unwrap();

    let result = skill_install_rollback_in(
        &store,
        &json!({
            "agent": "codex",
            "snapshotId": installed["rollbackSnapshotId"].as_str().unwrap()
        }),
    );

    assert!(result.is_err());
    assert_eq!(
        fs::read_to_string(external.join("sentinel")).unwrap(),
        "preserve"
    );
}
