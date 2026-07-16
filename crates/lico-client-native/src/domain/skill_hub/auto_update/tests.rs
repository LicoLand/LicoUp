use super::*;
use crate::domain::skill_hub::{pair_approve_in, pair_request_in, skill_install_apply_in};
use crate::platform::file_security::open_private_lock_file;
use fs2::FileExt;
use std::{env, fs, path::Path, path::PathBuf};
use time::Duration;
use uuid::Uuid;

#[test]
fn enabled_policy_is_executed_by_a_due_background_tick() {
    let store = test_store("scheduled");
    pair(&store, "codex");
    let root = temp_dir("root");
    let original = skill_package("original", "original\n");
    install(&store, &root, &original);
    let mirror = skill_package("mirror", "updated\n");

    let configured = configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": true,
            "sourcePath": mirror.to_string_lossy(),
            "directUserAction": true,
            "intervalSeconds": model::MIN_INTERVAL_SECONDS
        }),
    )
    .unwrap();
    assert_eq!(configured["executionMode"], "background-periodic");

    let result = tick_at(&store, OffsetDateTime::now_utc() + Duration::seconds(1)).unwrap();
    assert_eq!(result["selectedCount"], 1);
    assert_eq!(result["updatedCount"], 1);
    assert_eq!(
        fs::read_to_string(root.join("review-helper/references/guide.md")).unwrap(),
        "updated\n"
    );
}

#[test]
fn disabled_and_unconfigured_skills_never_run() {
    let store = test_store("disabled");
    pair(&store, "codex");
    let root = temp_dir("root");
    let original = skill_package("original", "original\n");
    install(&store, &root, &original);
    configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": false,
            "directUserAction": true
        }),
    )
    .unwrap();

    let result = tick_at(&store, OffsetDateTime::now_utc() + Duration::days(2)).unwrap();
    assert_eq!(result["selectedCount"], 0);
    assert_eq!(result["updatedCount"], 0);
}

#[test]
fn overlapping_tick_returns_busy_without_running_a_second_batch() {
    let store = test_store("reentry");
    let lock = open_private_lock_file(&store.root().join(model::LOCK_FILE)).unwrap();
    lock.try_lock_exclusive().unwrap();

    let result = tick_at(&store, OffsetDateTime::now_utc()).unwrap();
    assert_eq!(result["status"], "busy");
    assert_eq!(result["selectedCount"], 0);
    let configure_error = configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": false,
            "directUserAction": true
        }),
    )
    .unwrap_err();
    assert!(configure_error.to_string().contains("currently running"));
}

#[test]
fn failed_source_is_redacted_and_retried_after_bounded_backoff() {
    let store = test_store("failure");
    pair(&store, "codex");
    let root = temp_dir("root");
    let original = skill_package("original", "original\n");
    install(&store, &root, &original);
    let mirror = skill_package("mirror", "updated\n");
    configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": true,
            "sourcePath": mirror.to_string_lossy(),
            "directUserAction": true,
            "intervalSeconds": model::MIN_INTERVAL_SECONDS
        }),
    )
    .unwrap();
    fs::remove_dir_all(&mirror).unwrap();
    let now = OffsetDateTime::now_utc() + Duration::seconds(1);
    let failed = tick_at(&store, now).unwrap();
    assert_eq!(failed["status"], "partial_failure");
    assert_eq!(failed["results"][0]["status"], "update_failed");
    assert!(
        failed
            .to_string()
            .find(mirror.to_string_lossy().as_ref())
            .is_none()
    );

    write_skill_package_at(&mirror, "recovered\n");
    let retried = tick_at(
        &store,
        now + Duration::seconds(model::MIN_INTERVAL_SECONDS + 1),
    )
    .unwrap();
    assert_eq!(retried["updatedCount"], 1);
}

#[test]
fn claimed_job_is_cancelled_when_user_disables_or_changes_its_source() {
    let store = test_store("policy-race");
    pair(&store, "codex");
    let root = temp_dir("root");
    let original = skill_package("original", "original\n");
    install(&store, &root, &original);
    let mirror = skill_package("mirror", "updated\n");
    configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": true,
            "sourcePath": mirror.to_string_lossy(),
            "directUserAction": true
        }),
    )
    .unwrap();
    let now = OffsetDateTime::now_utc() + Duration::seconds(1);
    let (jobs, _) = schedule::claim_jobs(&store, now, model::Selection::Due).unwrap();
    assert_eq!(jobs.len(), 1);

    configure(
        &store,
        &json!({
            "agent": "codex",
            "skill": "review-helper",
            "enabled": false,
            "directUserAction": true
        }),
    )
    .unwrap();
    assert!(!schedule::job_is_still_authorized(&store, &jobs[0]).unwrap());
    assert_eq!(
        fs::read_to_string(root.join("review-helper/references/guide.md")).unwrap(),
        "original\n"
    );
}

fn pair(store: &ClientStateStore, agent: &str) {
    pair_request_in(store, &json!({"agent": agent})).unwrap();
    pair_approve_in(store, &json!({"agent": agent})).unwrap();
}

fn install(store: &ClientStateStore, root: &Path, source: &Path) {
    skill_install_apply_in(
        store,
        &json!({
            "agent": "codex",
            "sourcePath": source.to_string_lossy(),
            "installRoot": root.to_string_lossy()
        }),
    )
    .unwrap();
}

fn skill_package(name: &str, guide: &str) -> PathBuf {
    let root = temp_dir(name);
    write_skill_package_at(&root, guide);
    root
}

fn write_skill_package_at(root: &Path, guide: &str) {
    fs::create_dir_all(root.join("references")).unwrap();
    fs::write(
        root.join("SKILL.md"),
        "---\nname: review-helper\ntitle: Review Helper\nversion: 1.0.0\n---\n",
    )
    .unwrap();
    fs::write(root.join("references/guide.md"), guide).unwrap();
}

fn test_store(name: &str) -> ClientStateStore {
    ClientStateStore::new(temp_dir(name)).unwrap()
}

fn temp_dir(name: &str) -> PathBuf {
    let path = env::temp_dir().join(format!("lico-skill-auto-update-{name}-{}", Uuid::new_v4()));
    fs::create_dir_all(&path).unwrap();
    path.canonicalize().unwrap()
}
