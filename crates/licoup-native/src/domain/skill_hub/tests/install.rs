use super::super::*;
use super::support::*;

#[test]
fn skill_install_plan_parses_github_tree_source() {
    let source = skill_source(&json!({
        "url": "https://github.com/example/tools/tree/release/skills/review-helper"
    }))
    .unwrap();

    let github = source.github.unwrap();
    assert_eq!(github.owner, "example");
    assert_eq!(github.repo, "tools");
    assert_eq!(github.ref_name, "release");
    assert_eq!(github.path, "skills/review-helper");
}

#[test]
fn skill_install_plan_reports_conflict_without_overwrite() {
    let store = test_store("install-plan-conflict");
    pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
    pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();

    let source_dir = create_skill_package("install-plan-conflict-source", "review-helper");
    let install_root = temp_test_dir("install-plan-conflict-root");
    fs::create_dir_all(install_root.join("review-helper")).unwrap();

    let result = skill_install_plan_in(
        &store,
        &json!({
            "agent": "codex",
            "sourcePath": display_path(source_dir),
            "installRoot": display_path(install_root),
        }),
    )
    .unwrap();

    assert_eq!(result["ok"], true);
    assert_eq!(result["status"], "conflict");
    assert_eq!(result["installAllowed"], false);
    assert_eq!(result["installBlockedReason"], "destination_exists");
}

#[test]
fn skill_install_apply_installs_visible_skill_and_rolls_back() {
    let store = test_store("install-apply");
    pair_request_in(
        &store,
        &json!({"agent": "codex", "target": "codex", "defaultVisibilityPolicy": "deny-by-default"}),
    )
    .unwrap();
    pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();

    let source_dir = create_skill_package("install-apply-source", "review-helper");
    let install_root = temp_test_dir("install-apply-root");
    let params = json!({
        "agent": "codex",
        "sourcePath": display_path(source_dir.clone()),
        "installRoot": display_path(install_root.clone()),
        "pin": true,
    });

    let plan = skill_install_plan_in(&store, &params).unwrap();
    assert_eq!(plan["ok"], true);
    assert_eq!(plan["status"], "planned");
    assert_eq!(plan["skillId"], "review-helper");
    assert_eq!(plan["installAllowed"], true);
    assert_eq!(plan["fileCount"], 2);

    let installed = skill_install_apply_in(&store, &params).unwrap();
    assert_eq!(installed["ok"], true);
    assert_eq!(installed["status"], "installed");
    assert_eq!(installed["skillId"], "review-helper");
    assert!(
        install_root
            .join("review-helper")
            .join("SKILL.md")
            .is_file()
    );
    assert!(
        install_root
            .join("review-helper")
            .join("references")
            .join("guide.md")
            .is_file()
    );

    let visible = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
    assert_eq!(visible["skills"].as_array().unwrap().len(), 1);
    assert_eq!(visible["skills"][0]["skillId"], "review-helper");
    assert_eq!(visible["skills"][0]["installer"], SKILL_INSTALLER_PROTOCOL);

    let pins = store.read_collection("pins").unwrap();
    let pinned = pins["items"].as_array().unwrap().iter().any(|item| {
        item["agentId"] == "codex"
            && item["skillId"] == "review-helper"
            && item["version"] == "1.2.3"
    });
    assert!(pinned);

    let snapshot_id = installed["rollbackSnapshotId"].as_str().unwrap();
    let rolled_back = skill_install_rollback_in(
        &store,
        &json!({"agent": "codex", "snapshotId": snapshot_id}),
    )
    .unwrap();
    assert_eq!(rolled_back["status"], "rolled_back");
    assert!(!install_root.join("review-helper").exists());

    let visible_after = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
    assert!(visible_after["skills"].as_array().unwrap().is_empty());
}
