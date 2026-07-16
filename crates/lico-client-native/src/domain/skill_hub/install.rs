use super::*;

pub(super) fn skill_install_plan_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let source = skill_source(params)?;
    let install_root = match resolve_install_root(&agent_id, params) {
        Ok(root) => root,
        Err(error) => {
            return Ok(json!({
                "ok": false,
                "status": "unsupported_target_adapter",
                "agentId": agent_id,
                "source": source.public_summary(),
                "message": error.to_string(),
                "requiredAction": "provide_install_root"
            }));
        }
    };
    let preview = preview_skill_package(&source)?;
    let skill_id = skill_id_for_install(params, &preview)?;
    let install_dir = install_root.join(&skill_id);
    if !is_path_inside(&install_root, &install_dir) {
        return Ok(json!({
            "ok": false,
            "status": "path_boundary_rejected",
            "agentId": agent_id,
            "skillId": skill_id,
            "installRoot": display_path(install_root),
            "installDir": display_path(install_dir)
        }));
    }
    let exists = install_dir.exists();
    let overwrite = bool_param(params, "overwrite").unwrap_or(false);
    Ok(json!({
        "ok": true,
        "status": if exists && !overwrite { "conflict" } else { "planned" },
        "agentId": agent_id,
        "skillId": skill_id,
        "title": preview.title,
        "description": preview.description,
        "version": preview.version,
        "source": source.public_summary(),
        "installRoot": display_path(install_root),
        "installDir": display_path(install_dir),
        "installAllowed": !exists || overwrite,
        "installBlockedReason": if exists && !overwrite { "destination_exists" } else { "none" },
        "packageDigestSha256": preview.digest_sha256,
        "fileCount": preview.file_count,
        "requiresConfirmation": true,
        "rollbackAvailable": true
    }))
}

pub(super) fn skill_install_apply_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let source = skill_source(params)?;
    let install_root = match resolve_install_root(&agent_id, params) {
        Ok(root) => root,
        Err(error) => {
            return Ok(json!({
                "ok": false,
                "status": "unsupported_target_adapter",
                "agentId": agent_id,
                "source": source.public_summary(),
                "message": error.to_string(),
                "requiredAction": "provide_install_root"
            }));
        }
    };
    let resolved = resolve_skill_package(&source)?;
    let preview = inspect_skill_dir(&resolved.package_dir)?;
    verify_expected_package_digest(params, &preview.digest_sha256)?;
    let skill_id = skill_id_for_install(params, &preview)?;
    let install_dir = install_root.join(&skill_id);
    if !is_path_inside(&install_root, &install_dir) {
        return Ok(json!({
            "ok": false,
            "status": "path_boundary_rejected",
            "agentId": agent_id,
            "skillId": skill_id,
            "installRoot": display_path(install_root),
            "installDir": display_path(install_dir)
        }));
    }
    let overwrite = bool_param(params, "overwrite").unwrap_or(false);
    if install_dir.exists() && !overwrite {
        return Ok(json!({
            "ok": false,
            "status": "destination_exists",
            "agentId": agent_id,
            "skillId": skill_id,
            "installDir": display_path(install_dir),
            "message": "Skill destination already exists. Re-run with --overwrite true after reviewing the plan."
        }));
    }

    ensure_private_dir(&install_root)?;
    let previous_skill_record = find_installed_skill_record(store, &agent_id, &skill_id)?;
    let auto_update_policy = previous_skill_record
        .as_ref()
        .and_then(|record| record.get("autoUpdate"))
        .cloned()
        .unwrap_or_else(|| json!({"enabled": false}));
    let snapshot = capture_skill_install_snapshot(
        store,
        &agent_id,
        &skill_id,
        &install_root,
        &install_dir,
        json!({
            "operation": "skill.install.apply",
            "source": source.public_summary(),
            "packageDigestSha256": preview.digest_sha256.clone(),
            "previousSkillRecord": previous_skill_record
        }),
    )?;
    install_skill_dir(
        &resolved.package_dir,
        &install_root,
        &install_dir,
        overwrite,
    )?;
    let installed_digest = digest_directory(&install_dir)?;
    let installed_at = timestamp();
    let receipt_id = format!("skill-install-{}", uuid_v4());
    let record = json!({
        "kind": "skill",
        "skillId": skill_id.clone(),
        "agentId": agent_id.clone(),
        "target": agent_id.clone(),
        "title": preview.title.clone(),
        "description": preview.description.clone(),
        "version": preview.version.clone(),
        "path": display_path(install_dir.clone()),
        "installRoot": display_path(install_root.clone()),
        "source": source.public_summary(),
        "protocolStatus": "installed",
        "installer": SKILL_INSTALLER_PROTOCOL,
        "packageDigestSha256": installed_digest.clone(),
        "declaredPackageDigestSha256": preview.digest_sha256.clone(),
        "fileCount": preview.file_count,
        "installedAt": installed_at.clone(),
        "installReceiptId": receipt_id.clone(),
        "rollbackSnapshotId": snapshot.snapshot_id.clone(),
        "rollbackSnapshotPath": display_path(snapshot.snapshot_path.clone()),
        "rollbackCommand": "lico-client skill install rollback --agent <agent> --snapshot-id <snapshotId>",
        "autoUpdate": auto_update_policy
    });
    upsert_installed_skill_record(store, &agent_id, &skill_id, record.clone())?;
    if bool_param(params, "pin").unwrap_or(false) {
        let pin_version = record
            .get("version")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("local");
        let _ = skill_pin_in(
            store,
            &json!({"agent": agent_id.clone(), "skill": skill_id.clone(), "version": pin_version}),
        )?;
    }
    append_activity(
        store,
        "skill.installed",
        json!({
            "target": agent_id.clone(),
            "agentId": agent_id.clone(),
            "skillId": skill_id.clone(),
            "installDir": display_path(install_dir.clone()),
            "packageDigestSha256": installed_digest.clone(),
            "rollbackSnapshotId": snapshot.snapshot_id.clone()
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "installed",
        "agentId": agent_id,
        "skillId": skill_id,
        "installDir": display_path(install_dir),
        "installRoot": display_path(install_root),
        "source": source.public_summary(),
        "skill": record,
        "rollbackSnapshotId": snapshot.snapshot_id.clone(),
        "rollbackSnapshotPath": display_path(snapshot.snapshot_path.clone()),
        "packageDigestSha256": installed_digest
    }))
}

fn verify_expected_package_digest(params: &Value, actual: &str) -> Result<()> {
    let Some(expected) = string_param(
        params,
        &["expectedPackageDigestSha256", "expectedDigestSha256"],
        usize::MAX,
    ) else {
        return Ok(());
    };
    ensure!(
        expected.len() == 64 && expected.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "expected skill package digest is invalid"
    );
    ensure!(
        expected.eq_ignore_ascii_case(actual),
        "skill package changed after the reviewed plan"
    );
    Ok(())
}

pub(super) fn skill_install_rollback_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    ensure!(
        is_agent_approved(store, &agent_id)?,
        "skill install rollback requires an approved agent pairing"
    );
    let snapshot_id = string_param(params, &["snapshotId", "snapshot"], 0)
        .ok_or_else(|| anyhow!("skill install rollback requires --snapshot-id <id>"))?;
    validate_snapshot_id(&snapshot_id)?;
    let snapshot_path = store
        .root()
        .join("snapshots")
        .join(format!("{snapshot_id}.json"));
    let raw = read_private_text_bounded(&snapshot_path, SKILL_SNAPSHOT_MAX_BYTES)?
        .ok_or_else(|| anyhow!("skill install rollback snapshot is missing"))?;
    let snapshot: Value = serde_json::from_str(&raw)?;
    ensure!(
        snapshot.get("kind").and_then(Value::as_str) == Some("skill-install-directory"),
        "snapshot is not a skill install directory snapshot"
    );
    ensure!(
        snapshot.get("snapshotId").and_then(Value::as_str) == Some(snapshot_id.as_str()),
        "skill install rollback snapshot id binding mismatch"
    );
    ensure!(
        snapshot.get("agentId").and_then(Value::as_str) == Some(agent_id.as_str()),
        "skill install rollback snapshot belongs to another agent"
    );
    let skill_id = snapshot
        .get("skillId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("snapshot is missing skillId"))?
        .to_string();
    ensure!(
        sanitize_skill_id(&skill_id)? == skill_id,
        "skill install rollback snapshot contains an invalid skill id"
    );
    let install_root = snapshot
        .get("installRoot")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("snapshot is missing installRoot"))?;
    let install_dir = snapshot
        .get("installDir")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("snapshot is missing installDir"))?;
    let installed_record = find_installed_skill_record(store, &agent_id, &skill_id)?
        .ok_or_else(|| anyhow!("skill install rollback has no active install receipt"))?;
    ensure!(
        installed_record
            .get("rollbackSnapshotId")
            .and_then(Value::as_str)
            == Some(snapshot_id.as_str()),
        "skill install rollback snapshot is not authorized by the active install receipt"
    );
    ensure!(
        installed_record.get("installRoot").and_then(Value::as_str)
            == snapshot.get("installRoot").and_then(Value::as_str)
            && installed_record.get("path").and_then(Value::as_str)
                == snapshot.get("installDir").and_then(Value::as_str),
        "skill install rollback path binding mismatch"
    );
    validate_skill_install_boundary(&install_root, &install_dir, &skill_id)?;

    restore_skill_install_snapshot(&snapshot, &install_root, &install_dir)?;
    remove_installed_skill_record(store, &agent_id, &skill_id)?;
    if let Some(previous) = snapshot
        .get("metadata")
        .and_then(|metadata| metadata.get("previousSkillRecord"))
        .filter(|value| value.is_object())
        .cloned()
    {
        upsert_installed_skill_record(store, &agent_id, &skill_id, previous)?;
    }
    remove_private_state_marker(&snapshot_path)?;
    append_activity(
        store,
        "skill.install.rolled_back",
        json!({
            "target": agent_id,
            "agentId": agent_id,
            "skillId": skill_id,
            "snapshotId": snapshot_id,
            "installDir": display_path(install_dir.clone())
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "rolled_back",
        "agentId": agent_id,
        "skillId": skill_id,
        "snapshotId": snapshot_id,
        "snapshotPath": display_path(snapshot_path),
        "installDir": display_path(install_dir)
    }))
}
