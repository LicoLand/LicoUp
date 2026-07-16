use super::package::{
    MAX_SKILL_BYTES, collect_regular_files, sanitize_skill_id, validate_relative_path,
};
use super::{
    SKILL_INSTALL_JOURNAL_MAX_BYTES, SKILL_INSTALL_JOURNAL_SCHEMA, directory_exists_no_follow,
    uuid_v4,
};
use crate::platform::file_security::{
    atomic_write_private_text_bounded, ensure_private_dir, open_private_lock_file,
    read_private_text_bounded, remove_private_state_marker, validate_no_symlink_ancestors,
};
use anyhow::{Result, anyhow, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct SkillInstallJournal {
    pub(super) schema_version: String,
    pub(super) target_name: String,
    pub(super) temporary_name: String,
    pub(super) backup_name: String,
    pub(super) phase: String,
}

pub(super) fn install_skill_dir(
    source_dir: &Path,
    install_root: &Path,
    install_dir: &Path,
    overwrite: bool,
) -> Result<()> {
    ensure_private_dir(install_root)?;
    validate_no_symlink_ancestors(install_root)?;
    let lock_path = install_root.join(".lico-skill-install.lock");
    let lock = open_private_lock_file(&lock_path)?;
    lock.lock_exclusive()?;
    let result = install_skill_dir_locked(source_dir, install_root, install_dir, overwrite);
    let _ = FileExt::unlock(&lock);
    result
}

fn install_skill_dir_locked(
    source_dir: &Path,
    install_root: &Path,
    install_dir: &Path,
    overwrite: bool,
) -> Result<()> {
    recover_skill_install_journal(install_root)?;
    let target_name = managed_child_name(install_root, install_dir, None)?;
    let files = collect_regular_files(source_dir)?;
    let temporary_name = format!(".lico-skill-install-{}-tmp", uuid_v4().replace('-', ""));
    let temp_dir = managed_child_path(install_root, &temporary_name, Some(".lico-skill-install-"))?;
    fs::create_dir(&temp_dir)?;
    let stage_result = (|| -> Result<()> {
        let mut copied_bytes = 0u64;
        for relative in files {
            validate_relative_path(&relative)?;
            let source = source_dir.join(&relative);
            validate_no_symlink_ancestors(&source)?;
            let destination = temp_dir.join(&relative);
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)?;
                validate_no_symlink_ancestors(parent)?;
            }
            let mut input_options = fs::OpenOptions::new();
            input_options.read(true);
            let mut output_options = fs::OpenOptions::new();
            output_options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                input_options.custom_flags(nix::libc::O_NOFOLLOW);
                output_options
                    .mode(0o600)
                    .custom_flags(nix::libc::O_NOFOLLOW);
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
                input_options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
                output_options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
            }
            let input = input_options.open(&source)?;
            let mut output = output_options.open(&destination)?;
            let remaining = MAX_SKILL_BYTES.saturating_sub(copied_bytes);
            let copied = std::io::copy(&mut input.take(remaining + 1), &mut output)?;
            copied_bytes = copied_bytes
                .checked_add(copied)
                .ok_or_else(|| anyhow!("skill_package_too_large"))?;
            ensure!(copied_bytes <= MAX_SKILL_BYTES, "skill_package_too_large");
            use std::io::Write as _;
            output.flush()?;
            output.sync_all()?;
        }
        Ok(())
    })();
    if let Err(error) = stage_result {
        let _ = fs::remove_dir_all(&temp_dir);
        return Err(error);
    }

    if directory_exists_no_follow(install_dir)? {
        if !overwrite {
            fs::remove_dir_all(&temp_dir)?;
            return Err(anyhow!("skill_destination_exists"));
        }
        let backup_name = format!(".lico-skill-install-{}-backup", uuid_v4().replace('-', ""));
        let backup_dir =
            managed_child_path(install_root, &backup_name, Some(".lico-skill-install-"))?;
        let mut journal = SkillInstallJournal {
            schema_version: SKILL_INSTALL_JOURNAL_SCHEMA.to_string(),
            target_name,
            temporary_name,
            backup_name,
            phase: "prepared".to_string(),
        };
        write_skill_install_journal(install_root, &journal)?;
        fs::rename(install_dir, &backup_dir)?;
        journal.phase = "backup-created".to_string();
        write_skill_install_journal(install_root, &journal)?;
        if let Err(error) = fs::rename(&temp_dir, install_dir) {
            if fs::rename(&backup_dir, install_dir).is_ok() {
                let _ = remove_private_state_marker(&skill_install_journal_path(install_root));
            }
            return Err(error.into());
        }

        // Installation is committed. Cleanup remains journal-backed and must
        // not turn a successful state transition into an error result.
        journal.phase = "committed".to_string();
        if write_skill_install_journal(install_root, &journal).is_ok()
            && fs::remove_dir_all(&backup_dir).is_ok()
        {
            let _ = remove_private_state_marker(&skill_install_journal_path(install_root));
        }
    } else if let Err(error) = fs::rename(&temp_dir, install_dir) {
        let _ = fs::remove_dir_all(&temp_dir);
        return Err(error.into());
    }
    Ok(())
}

pub(super) fn skill_install_journal_path(install_root: &Path) -> PathBuf {
    install_root.join(".lico-skill-install-journal")
}

pub(super) fn write_skill_install_journal(
    install_root: &Path,
    journal: &SkillInstallJournal,
) -> Result<()> {
    ensure!(
        journal.schema_version == SKILL_INSTALL_JOURNAL_SCHEMA,
        "skill_install_journal_schema_invalid"
    );
    let body = format!("{}\n", serde_json::to_string(journal)?);
    atomic_write_private_text_bounded(
        &skill_install_journal_path(install_root),
        &body,
        SKILL_INSTALL_JOURNAL_MAX_BYTES,
    )
}

pub(super) fn recover_skill_install_journal(install_root: &Path) -> Result<()> {
    let journal_path = skill_install_journal_path(install_root);
    let Some(body) = read_private_text_bounded(&journal_path, SKILL_INSTALL_JOURNAL_MAX_BYTES)?
    else {
        return Ok(());
    };
    let journal: SkillInstallJournal = serde_json::from_str(&body)?;
    ensure!(
        journal.schema_version == SKILL_INSTALL_JOURNAL_SCHEMA,
        "skill_install_journal_schema_unsupported"
    );
    let target = managed_child_path(install_root, &journal.target_name, None)?;
    let temporary = managed_child_path(
        install_root,
        &journal.temporary_name,
        Some(".lico-skill-install-"),
    )?;
    let backup = managed_child_path(
        install_root,
        &journal.backup_name,
        Some(".lico-skill-install-"),
    )?;
    let target_exists = directory_exists_no_follow(&target)?;
    let temporary_exists = directory_exists_no_follow(&temporary)?;
    let backup_exists = directory_exists_no_follow(&backup)?;

    match journal.phase.as_str() {
        "prepared" | "backup-created" => match (target_exists, temporary_exists, backup_exists) {
            (false, _, true) => {
                fs::rename(&backup, &target)?;
                if temporary_exists {
                    fs::remove_dir_all(&temporary)?;
                }
            }
            (true, false, true) => {
                fs::remove_dir_all(&backup)?;
            }
            (true, true, false) | (true, false, false) => {
                if temporary_exists {
                    fs::remove_dir_all(&temporary)?;
                }
            }
            _ => return Err(anyhow!("skill_install_journal_state_ambiguous")),
        },
        "committed" => {
            ensure!(
                target_exists && !temporary_exists,
                "skill_install_journal_committed_state_invalid"
            );
            if backup_exists {
                fs::remove_dir_all(&backup)?;
            }
        }
        _ => return Err(anyhow!("skill_install_journal_phase_invalid")),
    }
    remove_private_state_marker(&journal_path)?;
    Ok(())
}

fn managed_child_name(
    install_root: &Path,
    child: &Path,
    required_prefix: Option<&str>,
) -> Result<String> {
    let relative = child
        .strip_prefix(install_root)
        .map_err(|_| anyhow!("skill_managed_path_outside_root"))?;
    ensure!(
        relative.components().count() == 1,
        "skill_managed_path_not_direct_child"
    );
    let name = relative
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow!("skill_managed_path_name_invalid"))?
        .to_string();
    if let Some(prefix) = required_prefix {
        ensure!(
            name.starts_with(prefix),
            "skill_managed_path_prefix_invalid"
        );
    }
    Ok(name)
}

fn managed_child_path(
    install_root: &Path,
    name: &str,
    required_prefix: Option<&str>,
) -> Result<PathBuf> {
    let relative = Path::new(name);
    ensure!(
        relative.components().count() == 1
            && matches!(relative.components().next(), Some(Component::Normal(_))),
        "skill_install_journal_child_invalid"
    );
    if let Some(prefix) = required_prefix {
        ensure!(
            name.starts_with(prefix),
            "skill_install_journal_prefix_invalid"
        );
    } else {
        ensure!(
            sanitize_skill_id(name)? == name,
            "skill_install_target_invalid"
        );
    }
    let path = install_root.join(relative);
    validate_no_symlink_ancestors(&path)?;
    Ok(path)
}
