use super::package::{collect_regular_files, sanitize_skill_id, validate_relative_path};
use super::{
    SKILL_SNAPSHOT_MAX_BYTES, absolute_lexical_path, directory_exists_no_follow, display_path,
    install_skill_dir, timestamp, uuid_v4,
};
use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{
    atomic_write_private_text_bounded, validate_no_symlink_ancestors,
};
use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub(super) struct SkillInstallSnapshot {
    pub(super) snapshot_id: String,
    pub(super) snapshot_path: PathBuf,
}

pub(super) fn capture_skill_install_snapshot(
    store: &ClientStateStore,
    agent_id: &str,
    skill_id: &str,
    install_root: &Path,
    install_dir: &Path,
    metadata: Value,
) -> Result<SkillInstallSnapshot> {
    let snapshot_id = format!(
        "skill-install-{}-{}-{}",
        sanitize_skill_id(agent_id)?,
        skill_id,
        timestamp()
    );
    let snapshot_path = store
        .root()
        .join("snapshots")
        .join(format!("{snapshot_id}.json"));
    let existed = directory_exists_no_follow(install_dir)?;
    let files = if existed {
        let relative_files = collect_regular_files(install_dir)?;
        relative_files
            .iter()
            .map(|relative| {
                let bytes = fs::read(install_dir.join(relative))?;
                Ok(json!({
                    "path": relative.to_string_lossy(),
                    "encoding": "base64",
                    "content": general_purpose::STANDARD.encode(bytes)
                }))
            })
            .collect::<Result<Vec<_>>>()?
    } else {
        Vec::new()
    };
    let record = json!({
        "schemaVersion": "v0.0.1:schema:definition-1",
        "kind": "skill-install-directory",
        "snapshotId": snapshot_id,
        "agentId": agent_id,
        "skillId": skill_id,
        "installRoot": display_path(install_root.to_path_buf()),
        "installDir": display_path(install_dir.to_path_buf()),
        "capturedAt": timestamp(),
        "existed": existed,
        "files": files,
        "metadata": metadata
    });
    atomic_write_private_text_bounded(
        &snapshot_path,
        &format!("{}\n", serde_json::to_string_pretty(&record)?),
        SKILL_SNAPSHOT_MAX_BYTES,
    )?;
    Ok(SkillInstallSnapshot {
        snapshot_id,
        snapshot_path,
    })
}

pub(super) fn restore_skill_install_snapshot(
    snapshot: &Value,
    install_root: &Path,
    install_dir: &Path,
) -> Result<()> {
    if !snapshot
        .get("existed")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        if directory_exists_no_follow(install_dir)? {
            let quarantine = install_root.join(format!(
                ".lico-skill-rollback-{}-removed",
                uuid_v4().replace('-', "")
            ));
            fs::rename(install_dir, &quarantine)?;
            fs::remove_dir_all(quarantine)?;
        }
        return Ok(());
    }
    let materialized = install_root.join(format!(
        ".lico-skill-rollback-{}-source",
        uuid_v4().replace('-', "")
    ));
    fs::create_dir(&materialized)?;
    let files = snapshot
        .get("files")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("skill_snapshot_files_missing"))?;
    let restore_result = (|| -> Result<()> {
        for file in files {
            let relative = file
                .get("path")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .ok_or_else(|| anyhow!("skill_snapshot_path_missing"))?;
            validate_relative_path(&relative)?;
            let content = file
                .get("content")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("skill_snapshot_content_missing"))?;
            let bytes = general_purpose::STANDARD
                .decode(content)
                .map_err(|_| anyhow!("skill_snapshot_content_invalid"))?;
            let destination = materialized.join(relative);
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut options = fs::OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600).custom_flags(nix::libc::O_NOFOLLOW);
            }
            use std::io::Write as _;
            let mut output = options.open(&destination)?;
            output.write_all(&bytes)?;
            output.sync_all()?;
        }
        install_skill_dir(&materialized, install_root, install_dir, true)
    })();
    let _ = fs::remove_dir_all(&materialized);
    restore_result
}

pub(super) fn validate_snapshot_id(snapshot_id: &str) -> Result<()> {
    ensure!(
        snapshot_id.starts_with("skill-install-")
            && snapshot_id.len() <= 240
            && snapshot_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "skill_snapshot_id_invalid"
    );
    Ok(())
}

pub(super) fn validate_skill_install_boundary(
    install_root: &Path,
    install_dir: &Path,
    skill_id: &str,
) -> Result<()> {
    let root = absolute_lexical_path(install_root)?;
    let directory = absolute_lexical_path(install_dir)?;
    ensure!(
        directory == root.join(skill_id),
        "skill_rollback_boundary_invalid"
    );
    validate_no_symlink_ancestors(&root)?;
    validate_no_symlink_ancestors(&directory)?;
    let root_metadata = fs::symlink_metadata(&root)?;
    ensure!(
        root_metadata.is_dir() && !root_metadata.file_type().is_symlink(),
        "skill_rollback_root_invalid"
    );
    if let Ok(metadata) = fs::symlink_metadata(&directory) {
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "skill_rollback_target_invalid"
        );
    }
    Ok(())
}
