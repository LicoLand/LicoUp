use super::super::*;
use super::support::*;

#[test]
fn skill_install_journal_rejects_uncontained_recovery_paths() {
    let root = temp_test_dir("journal-traversal");
    ensure_private_dir(&root).unwrap();
    let journal = SkillInstallJournal {
        schema_version: SKILL_INSTALL_JOURNAL_SCHEMA.to_string(),
        target_name: "review-helper".to_string(),
        temporary_name: ".lico-skill-install-valid-tmp".to_string(),
        backup_name: "../outside".to_string(),
        phase: "backup-created".to_string(),
    };
    write_skill_install_journal(&root, &journal).unwrap();

    assert!(recover_skill_install_journal(&root).is_err());
    assert!(skill_install_journal_path(&root).exists());
}

#[test]
fn skill_install_journal_recovers_crash_after_backup_rename() {
    let root = temp_test_dir("journal-restore-backup");
    ensure_private_dir(&root).unwrap();
    let temporary_name = ".lico-skill-install-recovery-tmp";
    let backup_name = ".lico-skill-install-recovery-backup";
    let temporary = root.join(temporary_name);
    let backup = root.join(backup_name);
    fs::create_dir(&temporary).unwrap();
    fs::write(temporary.join("SKILL.md"), "new").unwrap();
    fs::create_dir(&backup).unwrap();
    fs::write(backup.join("SKILL.md"), "old").unwrap();
    write_skill_install_journal(
        &root,
        &SkillInstallJournal {
            schema_version: SKILL_INSTALL_JOURNAL_SCHEMA.to_string(),
            target_name: "review-helper".to_string(),
            temporary_name: temporary_name.to_string(),
            backup_name: backup_name.to_string(),
            phase: "backup-created".to_string(),
        },
    )
    .unwrap();

    recover_skill_install_journal(&root).unwrap();

    assert_eq!(
        fs::read_to_string(root.join("review-helper/SKILL.md")).unwrap(),
        "old"
    );
    assert!(!temporary.exists());
    assert!(!skill_install_journal_path(&root).exists());
}

#[test]
fn skill_install_journal_finishes_crash_after_commit_rename() {
    let root = temp_test_dir("journal-finish-commit");
    ensure_private_dir(&root).unwrap();
    let backup_name = ".lico-skill-install-committed-backup";
    fs::create_dir(root.join("review-helper")).unwrap();
    fs::write(root.join("review-helper/SKILL.md"), "new").unwrap();
    fs::create_dir(root.join(backup_name)).unwrap();
    fs::write(root.join(backup_name).join("SKILL.md"), "old").unwrap();
    write_skill_install_journal(
        &root,
        &SkillInstallJournal {
            schema_version: SKILL_INSTALL_JOURNAL_SCHEMA.to_string(),
            target_name: "review-helper".to_string(),
            temporary_name: ".lico-skill-install-committed-tmp".to_string(),
            backup_name: backup_name.to_string(),
            phase: "backup-created".to_string(),
        },
    )
    .unwrap();

    recover_skill_install_journal(&root).unwrap();

    assert_eq!(
        fs::read_to_string(root.join("review-helper/SKILL.md")).unwrap(),
        "new"
    );
    assert!(!root.join(backup_name).exists());
    assert!(!skill_install_journal_path(&root).exists());
}
