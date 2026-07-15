use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{
    atomic_write_private_text_bounded, ensure_private_dir, open_private_lock_file,
    read_private_text_bounded, remove_private_state_marker, validate_no_symlink_ancestors,
};
use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const STATUS_REQUESTED: &str = "requested";
const STATUS_APPROVED: &str = "approved";
const STATUS_REVOKED: &str = "revoked";
const SKILL_INSTALLER_PROTOCOL: &str = "github-skill-installer";
const SKILL_SNAPSHOT_MAX_BYTES: usize = 64 * 1024 * 1024;
const SKILL_INSTALL_JOURNAL_MAX_BYTES: usize = 16 * 1024;
const SKILL_INSTALL_JOURNAL_SCHEMA: &str = "lico.skill-install-journal.v1";

pub fn pair_request(params: &Value) -> Result<Value> {
    pair_request_in(&ClientStateStore::portable()?, params)
}

pub fn pair_approve(params: &Value) -> Result<Value> {
    pair_approve_in(&ClientStateStore::portable()?, params)
}

pub fn pair_revoke(params: &Value) -> Result<Value> {
    pair_revoke_in(&ClientStateStore::portable()?, params)
}

pub fn pair_list(params: &Value) -> Result<Value> {
    pair_list_in(&ClientStateStore::portable()?, params)
}

pub fn skill_list(params: &Value) -> Result<Value> {
    skill_list_in(&ClientStateStore::portable()?, params)
}

pub fn skill_get(params: &Value) -> Result<Value> {
    skill_get_in(&ClientStateStore::portable()?, params)
}

pub fn skill_visibility(params: &Value) -> Result<Value> {
    skill_visibility_in(&ClientStateStore::portable()?, params)
}

pub fn skill_pin(params: &Value) -> Result<Value> {
    skill_pin_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_plan(params: &Value) -> Result<Value> {
    skill_install_plan_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_apply(params: &Value) -> Result<Value> {
    skill_install_apply_in(&ClientStateStore::portable()?, params)
}

pub fn skill_install_rollback(params: &Value) -> Result<Value> {
    skill_install_rollback_in(&ClientStateStore::portable()?, params)
}

fn pair_request_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let target = target_id(params).unwrap_or_else(|| "manual".to_string());
    let target_kind = params
        .get("targetKind")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let label = params
        .get("label")
        .and_then(Value::as_str)
        .unwrap_or(&agent_id);
    let config_path = params
        .get("configPath")
        .and_then(Value::as_str)
        .unwrap_or("");
    let binary_path = params
        .get("binaryPath")
        .and_then(Value::as_str)
        .unwrap_or("");
    let pairing_id = format!("pair-{}", uuid_v4());
    let local_identity = format!("local-{}", uuid_v4());
    let visibility_policy = params
        .get("defaultVisibilityPolicy")
        .and_then(Value::as_str)
        .unwrap_or("deny-by-default");

    let mut document = store.read_collection("pairings")?;
    let items = collection_items_mut(&mut document)?;
    items.retain(|item| item.get("agentId").and_then(Value::as_str) != Some(&agent_id));
    let record = json!({
        "pairingId": pairing_id,
        "agentId": agent_id,
        "target": target,
        "targetKind": target_kind,
        "label": label,
        "configPath": config_path,
        "binaryPath": binary_path,
        "localIdentity": local_identity,
        "status": STATUS_REQUESTED,
        "requestedAt": timestamp(),
        "defaultVisibilityPolicy": visibility_policy,
        "scopes": [],
    });
    items.push(record.clone());
    store.write_collection("pairings", document)?;
    append_activity(
        store,
        "pairing.requested",
        json!({"target": target, "agentId": agent_id, "pairingId": pairing_id}),
    )?;
    Ok(json!({
        "ok": true,
        "status": STATUS_REQUESTED,
        "pairing": record
    }))
}

fn pair_approve_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    update_pairing_status(store, params, STATUS_APPROVED, "pairing.approved")
}

fn pair_revoke_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    update_pairing_status(store, params, STATUS_REVOKED, "pairing.revoked")
}

fn pair_list_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let document = store.read_collection("pairings")?;
    let mut pairings = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(agent) = params.get("agent").and_then(Value::as_str) {
        pairings.retain(|item| item.get("agentId").and_then(Value::as_str) == Some(agent));
    }
    Ok(json!({
        "ok": true,
        "pairings": pairings
    }))
}

fn update_pairing_status(
    store: &ClientStateStore,
    params: &Value,
    status: &str,
    event_type: &str,
) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let mut document = store.read_collection("pairings")?;
    let items = collection_items_mut(&mut document)?;
    let mut updated = None::<Value>;
    for item in items.iter_mut() {
        if item.get("agentId").and_then(Value::as_str) == Some(&agent_id) {
            item["status"] = json!(status);
            let status_time_key = match status {
                STATUS_APPROVED => "approvedAt",
                STATUS_REVOKED => "revokedAt",
                _ => "updatedAt",
            };
            item[status_time_key] = json!(timestamp());
            updated = Some(item.clone());
            break;
        }
    }
    let Some(record) = updated else {
        return Ok(json!({
            "ok": false,
            "error": "pairing_not_found",
            "agentId": agent_id
        }));
    };
    store.write_collection("pairings", document)?;
    append_activity(
        store,
        event_type,
        json!({
            "target": record.get("target").and_then(Value::as_str).unwrap_or(""),
            "agentId": agent_id
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": status,
        "pairing": record
    }))
}

fn skill_list_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let skills = visible_skills(store, &agent_id)?;
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "protocolStatus": "protocol_deferred",
        "skills": skills
    }))
}

fn skill_get_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    if !is_agent_approved(store, &agent_id)? {
        return Ok(pairing_required(&agent_id));
    }
    let skill_id = skill_id(params)?;
    let skill = find_skill(store, &skill_id)?;
    let Some(skill) = skill else {
        return Ok(protocol_deferred(&agent_id, &skill_id));
    };
    if is_hidden(store, &agent_id, &skill_id)? {
        return Ok(json!({
            "ok": false,
            "error": "hidden",
            "agentId": agent_id,
            "skillId": skill_id
        }));
    }
    if !is_skill_visible_by_policy(store, &agent_id, &skill_id)? {
        return Ok(json!({
            "ok": false,
            "error": "visibility_denied",
            "agentId": agent_id,
            "skillId": skill_id,
            "message": "Skill visibility denied by pairing defaultVisibilityPolicy"
        }));
    }
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skill": skill,
        "protocolStatus": "protocol_deferred",
        "execution": "not_supported",
        "dependencyInstall": "not_supported",
        "copyToWorkspace": "not_supported"
    }))
}

fn is_skill_visible_by_policy(
    store: &ClientStateStore,
    agent_id: &str,
    skill_id: &str,
) -> Result<bool> {
    let pairing = get_approved_pairing(store, agent_id)?;
    let policy = pairing
        .as_ref()
        .and_then(|p| p.get("defaultVisibilityPolicy").and_then(Value::as_str))
        .unwrap_or("allow-all");
    match policy {
        "deny-by-default" => Ok(is_explicitly_revealed(store, agent_id, skill_id)),
        _ => Ok(true),
    }
}

fn skill_visibility_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = skill_id(params)?;
    let hidden = bool_param(params, "hidden").unwrap_or_else(|| {
        params
            .get("visibility")
            .and_then(Value::as_str)
            .map(|value| value == "hidden" || value == "hide")
            .unwrap_or(false)
    });
    let mut document = store.read_collection("skills")?;
    let items = collection_items_mut(&mut document)?;
    upsert_policy_item(
        items,
        &agent_id,
        &skill_id,
        json!({
            "agentId": agent_id,
            "skillId": skill_id,
            "hidden": hidden,
            "visibility": if hidden { "hidden" } else { "allowed" },
            "updatedAt": timestamp()
        }),
    );
    store.write_collection("skills", document)?;
    append_activity(
        store,
        if hidden {
            "skill.hidden"
        } else {
            "skill.revealed"
        },
        json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id}),
    )?;
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skillId": skill_id,
        "hidden": hidden
    }))
}

fn skill_pin_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = skill_id(params)?;
    let version = params
        .get("version")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .and_then(|items| items.get(1))
                .and_then(Value::as_str)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("skill pin requires --version <version>"))?
        .to_string();
    let mut document = store.read_collection("pins")?;
    let items = collection_items_mut(&mut document)?;
    upsert_policy_item(
        items,
        &agent_id,
        &skill_id,
        json!({
            "agentId": agent_id,
            "skillId": skill_id,
            "version": version,
            "updatedAt": timestamp()
        }),
    );
    store.write_collection("pins", document)?;
    append_activity(
        store,
        "skill.pinned",
        json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id, "version": version}),
    )?;
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "skillId": skill_id,
        "version": version
    }))
}

fn skill_install_plan_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
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
    let preview = preview_skill_package(&source, params)?;
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

fn skill_install_apply_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
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
    let resolved = resolve_skill_package(&source, params)?;
    let preview = inspect_skill_dir(&resolved.package_dir)?;
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
        "rollbackCommand": "lico-client skill install rollback --agent <agent> --snapshot-id <snapshotId>"
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

fn skill_install_rollback_in(store: &ClientStateStore, params: &Value) -> Result<Value> {
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

fn visible_skills(store: &ClientStateStore, agent_id: &str) -> Result<Vec<Value>> {
    let pairing = get_approved_pairing(store, agent_id)?;
    let policy = pairing
        .as_ref()
        .and_then(|p| p.get("defaultVisibilityPolicy").and_then(Value::as_str))
        .unwrap_or("allow-all");

    let document = store.read_collection("skills")?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    Ok(items
        .into_iter()
        .filter(|item| item.get("kind").and_then(Value::as_str) == Some("skill"))
        .filter(|item| {
            let skill_id = item.get("skillId").and_then(Value::as_str).unwrap_or("");
            if is_hidden(store, agent_id, skill_id).unwrap_or(true) {
                return false;
            }
            match policy {
                "deny-by-default" => is_explicitly_revealed(store, agent_id, skill_id),
                _ => true,
            }
        })
        .collect())
}

#[derive(Clone, Debug)]
struct SkillSource {
    url: String,
    github: Option<GitHubSource>,
    local_path: Option<PathBuf>,
}

#[derive(Clone, Debug)]
struct GitHubSource {
    owner: String,
    repo: String,
    ref_name: String,
    path: String,
}

#[derive(Clone, Debug)]
struct ResolvedSkillPackage {
    package_dir: PathBuf,
    _temp_root: Option<PathBuf>,
}

#[derive(Clone, Debug)]
struct SkillPackagePreview {
    skill_id: String,
    title: String,
    description: String,
    version: String,
    digest_sha256: String,
    file_count: usize,
}

#[derive(Clone, Debug)]
struct SkillInstallSnapshot {
    snapshot_id: String,
    snapshot_path: PathBuf,
}

impl SkillSource {
    fn public_summary(&self) -> Value {
        if let Some(github) = &self.github {
            json!({
                "kind": "github",
                "url": self.url,
                "owner": github.owner,
                "repo": github.repo,
                "ref": github.ref_name,
                "path": github.path
            })
        } else if let Some(local_path) = &self.local_path {
            json!({
                "kind": "local-directory",
                "path": display_path(local_path.clone())
            })
        } else {
            json!({
                "kind": "unknown",
                "url": self.url
            })
        }
    }
}

fn skill_source(params: &Value) -> Result<SkillSource> {
    if let Some(source_path) = params
        .get("sourcePath")
        .or_else(|| params.get("localPath"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return Ok(SkillSource {
            url: String::new(),
            github: None,
            local_path: Some(PathBuf::from(source_path)),
        });
    }
    let url = string_param(params, &["url", "githubUrl", "sourceUrl"], 0)
        .ok_or_else(|| anyhow!("skill install requires --url <github-url>"))?;
    let github = parse_github_skill_url(&url, params)?;
    Ok(SkillSource {
        url,
        github: Some(github),
        local_path: None,
    })
}

fn parse_github_skill_url(url: &str, params: &Value) -> Result<GitHubSource> {
    let trimmed = url.trim();
    let without_scheme = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .unwrap_or(trimmed);
    let without_host = without_scheme
        .strip_prefix("github.com/")
        .ok_or_else(|| anyhow!("only github.com skill URLs are supported"))?;
    let path_part = without_host.split(['?', '#']).next().unwrap_or("");
    let parts = path_part
        .split('/')
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>();
    if parts.len() < 2 {
        return Err(anyhow!("GitHub URL must include owner and repository"));
    }
    let owner = sanitize_github_segment(parts[0], "owner")?;
    let repo = sanitize_github_segment(parts[1].trim_end_matches(".git"), "repo")?;
    let explicit_ref = string_param(params, &["ref", "branch", "tag"], 2);
    let mut ref_name = explicit_ref.unwrap_or_else(|| "main".to_string());
    let mut skill_path = string_param(params, &["path", "skillPath"], 3).unwrap_or_default();
    if parts.get(2) == Some(&"tree") || parts.get(2) == Some(&"blob") {
        if parts.len() >= 4 && !params.get("ref").is_some() && !params.get("branch").is_some() {
            ref_name = sanitize_github_segment(parts[3], "ref")?;
        }
        if parts.len() >= 5 && skill_path.is_empty() {
            skill_path = parts[4..].join("/");
        }
    }
    Ok(GitHubSource {
        owner,
        repo,
        ref_name,
        path: sanitize_relative_path_text(&skill_path)?,
    })
}

fn sanitize_github_segment(value: &str, label: &str) -> Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.contains('\\')
        || trimmed == "."
        || trimmed == ".."
        || trimmed.chars().any(char::is_whitespace)
    {
        return Err(anyhow!("invalid GitHub {label} segment"));
    }
    Ok(trimmed.to_string())
}

fn sanitize_relative_path_text(value: &str) -> Result<String> {
    let trimmed = value.trim().trim_matches('/');
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let path = Path::new(trimmed);
    if path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::Prefix(_) | Component::RootDir
            )
        })
    {
        return Err(anyhow!(
            "skill path must be relative and stay inside the repository"
        ));
    }
    Ok(trimmed.replace('\\', "/"))
}

fn resolve_install_root(agent_id: &str, params: &Value) -> Result<PathBuf> {
    if let Some(root) = string_param(params, &["installRoot", "skillRoot"], 1) {
        return absolute_lexical_path(Path::new(&root));
    }
    match agent_id {
        "codex" => {
            let codex_home = env::var("CODEX_HOME")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from)
                .or_else(|| home_dir().map(|home| home.join(".codex")))
                .ok_or_else(|| anyhow!("cannot resolve CODEX_HOME or user home for Codex"))?;
            Ok(codex_home.join("skills"))
        }
        "claude-code" => {
            let claude_home = env::var("CLAUDE_HOME")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from)
                .or_else(|| home_dir().map(|home| home.join(".claude")))
                .ok_or_else(|| {
                    anyhow!("cannot resolve CLAUDE_HOME or user home for Claude Code")
                })?;
            Ok(claude_home.join("skills"))
        }
        _ => Err(anyhow!(
            "target adapter '{agent_id}' has no built-in skill install root"
        )),
    }
}

fn home_dir() -> Option<PathBuf> {
    directories::UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

fn preview_skill_package(source: &SkillSource, params: &Value) -> Result<SkillPackagePreview> {
    let resolved = resolve_skill_package(source, params)?;
    inspect_skill_dir(&resolved.package_dir)
}

fn resolve_skill_package(source: &SkillSource, params: &Value) -> Result<ResolvedSkillPackage> {
    if let Some(local_path) = &source.local_path {
        return Ok(ResolvedSkillPackage {
            package_dir: local_path.clone(),
            _temp_root: None,
        });
    }
    let github = source
        .github
        .as_ref()
        .ok_or_else(|| anyhow!("missing GitHub source"))?;
    let temp_root = env::temp_dir().join(format!("lico-skill-install-{}", uuid_v4()));
    fs::create_dir_all(&temp_root)?;
    let repo_dir = temp_root.join("repo");
    let repo_url = format!("https://github.com/{}/{}.git", github.owner, github.repo);
    let mut clone_args = vec![
        "clone".to_string(),
        "--depth".to_string(),
        "1".to_string(),
        "--branch".to_string(),
        github.ref_name.clone(),
        repo_url,
        display_path(repo_dir.clone()),
    ];
    if bool_param(params, "fullClone").unwrap_or(false) {
        clone_args = vec![
            "clone".to_string(),
            "--depth".to_string(),
            "1".to_string(),
            "--branch".to_string(),
            github.ref_name.clone(),
            format!("https://github.com/{}/{}.git", github.owner, github.repo),
            display_path(repo_dir.clone()),
        ];
    }
    let output = Command::new("git").args(&clone_args).output();
    match output {
        Ok(result) if result.status.success() => {}
        Ok(result) => {
            let stderr = String::from_utf8_lossy(&result.stderr);
            return Err(anyhow!(
                "git clone failed for GitHub skill source: {}",
                stderr.trim()
            ));
        }
        Err(error) => return Err(anyhow!("git is required for GitHub skill install: {error}")),
    }
    let package_dir = if github.path.is_empty() {
        repo_dir.clone()
    } else {
        repo_dir.join(&github.path)
    };
    Ok(ResolvedSkillPackage {
        package_dir,
        _temp_root: Some(temp_root),
    })
}

fn inspect_skill_dir(path: &Path) -> Result<SkillPackagePreview> {
    if !path.is_dir() {
        return Err(anyhow!("skill package path is not a directory"));
    }
    let skill_md = path.join("SKILL.md");
    if !skill_md.is_file() {
        return Err(anyhow!("skill package must contain SKILL.md"));
    }
    let metadata = parse_skill_metadata(&fs::read_to_string(&skill_md)?);
    let fallback_id = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("skill");
    let skill_id = sanitize_skill_id(
        metadata
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(fallback_id),
    )?;
    let title = metadata
        .get("title")
        .or_else(|| metadata.get("name"))
        .and_then(Value::as_str)
        .unwrap_or(&skill_id)
        .to_string();
    let description = metadata
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let version = metadata
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("local")
        .to_string();
    let files = collect_regular_files(path)?;
    Ok(SkillPackagePreview {
        skill_id,
        title,
        description,
        version,
        digest_sha256: digest_files(path, &files)?,
        file_count: files.len(),
    })
}

fn parse_skill_metadata(content: &str) -> Value {
    let mut lines = content.lines();
    if lines.next().map(str::trim) != Some("---") {
        return json!({});
    }
    let mut metadata = serde_json::Map::new();
    for line in lines {
        let trimmed = line.trim();
        if trimmed == "---" {
            break;
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        metadata.insert(
            key.to_string(),
            json!(value.trim().trim_matches('"').trim_matches('\'')),
        );
    }
    Value::Object(metadata)
}

fn sanitize_skill_id(value: &str) -> Result<String> {
    let id = value
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    if id.is_empty() {
        return Err(anyhow!("skill id is empty after normalization"));
    }
    Ok(id)
}

fn skill_id_for_install(params: &Value, preview: &SkillPackagePreview) -> Result<String> {
    if let Some(value) = string_param(params, &["name", "skill", "skillId"], 2) {
        return sanitize_skill_id(&value);
    }
    Ok(preview.skill_id.clone())
}

fn collect_regular_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::<PathBuf>::new();
    collect_regular_files_into(root, root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_regular_files_into(root: &Path, current: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            return Err(anyhow!(
                "skill package contains a symlink, which is not installed: {}",
                display_path(path)
            ));
        }
        if metadata.is_dir() {
            if entry.file_name().to_string_lossy() == ".git" {
                continue;
            }
            collect_regular_files_into(root, &path, files)?;
            continue;
        }
        if metadata.is_file() {
            let relative = path.strip_prefix(root)?.to_path_buf();
            validate_relative_path(&relative)?;
            files.push(relative);
        }
    }
    Ok(())
}

fn validate_relative_path(path: &Path) -> Result<()> {
    if path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::Prefix(_) | Component::RootDir
            )
        })
    {
        return Err(anyhow!("skill file path escapes package root"));
    }
    Ok(())
}

fn digest_directory(root: &Path) -> Result<String> {
    let files = collect_regular_files(root)?;
    digest_files(root, &files)
}

fn digest_files(root: &Path, files: &[PathBuf]) -> Result<String> {
    let mut hasher = Sha256::new();
    for relative in files {
        validate_relative_path(relative)?;
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(fs::read(root.join(relative))?);
        hasher.update([0]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn capture_skill_install_snapshot(
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
    let existed = install_dir.exists();
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

fn restore_skill_install_snapshot(
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
        .ok_or_else(|| anyhow!("snapshot is missing files"))?;
    let restore_result = (|| -> Result<()> {
        for file in files {
            let relative = file
                .get("path")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .ok_or_else(|| anyhow!("snapshot file is missing path"))?;
            validate_relative_path(&relative)?;
            let content = file
                .get("content")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("snapshot file is missing content"))?;
            let bytes = general_purpose::STANDARD.decode(content)?;
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

fn validate_snapshot_id(snapshot_id: &str) -> Result<()> {
    ensure!(
        snapshot_id.starts_with("skill-install-")
            && snapshot_id.len() <= 240
            && snapshot_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "skill install rollback snapshot id is invalid"
    );
    Ok(())
}

fn validate_skill_install_boundary(
    install_root: &Path,
    install_dir: &Path,
    skill_id: &str,
) -> Result<()> {
    let root = absolute_lexical_path(install_root)?;
    let directory = absolute_lexical_path(install_dir)?;
    ensure!(
        directory == root.join(skill_id),
        "skill install rollback target is outside the approved skill root"
    );
    validate_no_symlink_ancestors(&root)?;
    validate_no_symlink_ancestors(&directory)?;
    let root_metadata = fs::symlink_metadata(&root)?;
    ensure!(
        root_metadata.is_dir() && !root_metadata.file_type().is_symlink(),
        "skill install rollback root is not a stable directory"
    );
    if let Ok(metadata) = fs::symlink_metadata(&directory) {
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "skill install rollback target is not a stable directory"
        );
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SkillInstallJournal {
    schema_version: String,
    target_name: String,
    temporary_name: String,
    backup_name: String,
    phase: String,
}

fn install_skill_dir(
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
            let mut input = input_options.open(&source)?;
            let mut output = output_options.open(&destination)?;
            std::io::copy(&mut input, &mut output)?;
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
            return Err(anyhow!("destination exists"));
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
        journal.phase = "committed".to_string();
        write_skill_install_journal(install_root, &journal)?;
        fs::remove_dir_all(&backup_dir)?;
        remove_private_state_marker(&skill_install_journal_path(install_root))?;
    } else {
        if let Err(error) = fs::rename(&temp_dir, install_dir) {
            let _ = fs::remove_dir_all(&temp_dir);
            return Err(error.into());
        }
    }
    Ok(())
}

fn skill_install_journal_path(install_root: &Path) -> PathBuf {
    install_root.join(".lico-skill-install-journal")
}

fn write_skill_install_journal(install_root: &Path, journal: &SkillInstallJournal) -> Result<()> {
    ensure!(
        journal.schema_version == SKILL_INSTALL_JOURNAL_SCHEMA,
        "skill install journal schema is invalid"
    );
    let body = format!("{}\n", serde_json::to_string(journal)?);
    atomic_write_private_text_bounded(
        &skill_install_journal_path(install_root),
        &body,
        SKILL_INSTALL_JOURNAL_MAX_BYTES,
    )
}

fn recover_skill_install_journal(install_root: &Path) -> Result<()> {
    let journal_path = skill_install_journal_path(install_root);
    let Some(body) = read_private_text_bounded(&journal_path, SKILL_INSTALL_JOURNAL_MAX_BYTES)?
    else {
        return Ok(());
    };
    let journal: SkillInstallJournal = serde_json::from_str(&body)?;
    ensure!(
        journal.schema_version == SKILL_INSTALL_JOURNAL_SCHEMA,
        "skill install journal schema is unsupported"
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
                // The second rename committed before the phase update reached durable storage.
                fs::remove_dir_all(&backup)?;
            }
            (true, true, false) | (true, false, false) => {
                if temporary_exists {
                    fs::remove_dir_all(&temporary)?;
                }
            }
            _ => return Err(anyhow!("skill install journal state is ambiguous")),
        },
        "committed" => {
            ensure!(
                target_exists && !temporary_exists,
                "skill install committed journal target is missing or ambiguous"
            );
            if backup_exists {
                fs::remove_dir_all(&backup)?;
            }
        }
        _ => return Err(anyhow!("skill install journal phase is invalid")),
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
        .map_err(|_| anyhow!("managed skill path is outside its root"))?;
    ensure!(
        relative.components().count() == 1,
        "managed skill path is not a direct child"
    );
    let name = relative
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow!("managed skill path name is invalid"))?
        .to_string();
    if let Some(prefix) = required_prefix {
        ensure!(
            name.starts_with(prefix),
            "managed skill path prefix is invalid"
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
        "skill install journal contains an invalid child path"
    );
    if let Some(prefix) = required_prefix {
        ensure!(
            name.starts_with(prefix),
            "skill install journal child prefix is invalid"
        );
    } else {
        ensure!(
            sanitize_skill_id(name)? == name,
            "skill install target name is invalid"
        );
    }
    let path = install_root.join(relative);
    validate_no_symlink_ancestors(&path)?;
    Ok(path)
}

fn upsert_installed_skill_record(
    store: &ClientStateStore,
    agent_id: &str,
    skill_id: &str,
    record: Value,
) -> Result<()> {
    let mut document = store.read_collection("skills")?;
    let items = collection_items_mut(&mut document)?;
    items.retain(|item| {
        !(item.get("kind").and_then(Value::as_str) == Some("skill")
            && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
            && item.get("skillId").and_then(Value::as_str) == Some(skill_id))
    });
    items.push(record);
    upsert_policy_item(
        items,
        agent_id,
        skill_id,
        json!({
            "agentId": agent_id,
            "skillId": skill_id,
            "hidden": false,
            "visibility": "allowed",
            "updatedAt": timestamp()
        }),
    );
    store.write_collection("skills", document)?;
    Ok(())
}

fn remove_installed_skill_record(
    store: &ClientStateStore,
    agent_id: &str,
    skill_id: &str,
) -> Result<()> {
    let mut document = store.read_collection("skills")?;
    let items = collection_items_mut(&mut document)?;
    items.retain(|item| {
        !(item.get("kind").and_then(Value::as_str) == Some("skill")
            && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
            && item.get("skillId").and_then(Value::as_str) == Some(skill_id)
            && item.get("installer").and_then(Value::as_str) == Some(SKILL_INSTALLER_PROTOCOL))
    });
    store.write_collection("skills", document)?;
    Ok(())
}

fn find_installed_skill_record(
    store: &ClientStateStore,
    agent_id: &str,
    skill_id: &str,
) -> Result<Option<Value>> {
    let document = store.read_collection("skills")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| {
                    item.get("kind").and_then(Value::as_str) == Some("skill")
                        && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
                        && item.get("skillId").and_then(Value::as_str) == Some(skill_id)
                        && item.get("installer").and_then(Value::as_str)
                            == Some(SKILL_INSTALLER_PROTOCOL)
                })
                .cloned()
        }))
}

fn get_approved_pairing(store: &ClientStateStore, agent_id: &str) -> Result<Option<Value>> {
    let document = store.read_collection("pairings")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .find(|item| {
                    item.get("agentId").and_then(Value::as_str) == Some(agent_id)
                        && item.get("status").and_then(Value::as_str) == Some(STATUS_APPROVED)
                })
                .cloned()
        })
        .unwrap_or(None))
}

fn is_explicitly_revealed(store: &ClientStateStore, agent_id: &str, skill_id: &str) -> bool {
    let document = match store.read_collection("skills") {
        Ok(doc) => doc,
        Err(_) => return false,
    };
    document
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items.iter().any(|item| {
                item.get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or("visibility")
                    != "skill"
                    && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
                    && item.get("skillId").and_then(Value::as_str) == Some(skill_id)
                    && item.get("hidden").and_then(Value::as_bool) == Some(false)
                    && item.get("visibility").and_then(Value::as_str) == Some("allowed")
            })
        })
        .unwrap_or(false)
}

fn find_skill(store: &ClientStateStore, skill_id: &str) -> Result<Option<Value>> {
    let document = store.read_collection("skills")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| {
                    item.get("kind").and_then(Value::as_str) == Some("skill")
                        && item.get("skillId").and_then(Value::as_str) == Some(skill_id)
                })
                .cloned()
        }))
}

fn is_hidden(store: &ClientStateStore, agent_id: &str, skill_id: &str) -> Result<bool> {
    let document = store.read_collection("skills")?;
    Ok(document
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items.iter().any(|item| {
                item.get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or("visibility")
                    != "skill"
                    && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
                    && item.get("skillId").and_then(Value::as_str) == Some(skill_id)
                    && item.get("hidden").and_then(Value::as_bool).unwrap_or(false)
            })
        })
        .unwrap_or(false))
}

fn is_agent_approved(store: &ClientStateStore, agent_id: &str) -> Result<bool> {
    Ok(get_approved_pairing(store, agent_id)?.is_some())
}

fn upsert_policy_item(items: &mut Vec<Value>, agent_id: &str, skill_id: &str, replacement: Value) {
    items.retain(|item| {
        !(item
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("visibility")
            != "skill"
            && item.get("agentId").and_then(Value::as_str) == Some(agent_id)
            && item.get("skillId").and_then(Value::as_str) == Some(skill_id))
    });
    items.push(replacement);
}

fn collection_items_mut(document: &mut Value) -> Result<&mut Vec<Value>> {
    if document.get("items").and_then(Value::as_array).is_none() {
        document["items"] = json!([]);
    }
    document
        .get_mut("items")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| anyhow!("state collection is missing items array"))
}

fn append_activity(store: &ClientStateStore, event_type: &str, payload: Value) -> Result<Value> {
    store.activity_log().append(event_type, payload)
}

fn pairing_required(agent_id: &str) -> Value {
    json!({
        "ok": false,
        "error": "pairing_required",
        "agentId": agent_id
    })
}

fn protocol_deferred(agent_id: &str, skill_id: &str) -> Value {
    json!({
        "ok": false,
        "error": "protocol_deferred",
        "agentId": agent_id,
        "skillId": skill_id,
        "protocols": ["server Skill Registry", "MCP Skill Hub"]
    })
}

fn agent_id(params: &Value) -> Result<String> {
    string_param(params, &["agent", "agentId", "id"], 0)
        .ok_or_else(|| anyhow!("missing --agent <agent-id>"))
}

fn target_id(params: &Value) -> Option<String> {
    string_param(params, &["target"], 1)
}

fn skill_id(params: &Value) -> Result<String> {
    string_param(params, &["skill", "skillId", "id"], 0).ok_or_else(|| anyhow!("missing skill id"))
}

fn string_param(params: &Value, keys: &[&str], positional_index: usize) -> Option<String> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    params
        .get("positionals")
        .and_then(Value::as_array)
        .and_then(|items| items.get(positional_index))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| {
        value.as_bool().or_else(|| {
            value.as_str().map(|raw| {
                matches!(
                    raw.trim().to_ascii_lowercase().as_str(),
                    "1" | "true" | "yes" | "on" | "hidden" | "hide"
                )
            })
        })
    })
}

fn is_path_inside(parent_path: &Path, candidate_path: &Path) -> bool {
    let parent = normalize_lexical_path(parent_path);
    let candidate = normalize_lexical_path(candidate_path);
    candidate.starts_with(parent)
}

fn normalize_lexical_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            _ => normalized.push(component.as_os_str()),
        }
    }
    normalized
}

fn absolute_lexical_path(path: &Path) -> Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()?.join(path)
    };
    ensure!(
        !absolute
            .components()
            .any(|component| matches!(component, Component::ParentDir)),
        "managed skill path contains a parent traversal component"
    );
    Ok(normalize_lexical_path(&absolute))
}

fn directory_exists_no_follow(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                "managed skill path is not a stable directory"
            );
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", now.as_secs(), now.subsec_nanos())
}

fn uuid_v4() -> String {
    Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn pairing_skill_cli_pair_request_approve_revoke_list() {
        let store = test_store("pairing-lifecycle");
        let requested =
            pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
        assert_eq!(requested["status"], STATUS_REQUESTED);

        let approved = pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(approved["status"], STATUS_APPROVED);
        assert!(is_agent_approved(&store, "codex").unwrap());

        let listed = pair_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(listed["pairings"].as_array().unwrap().len(), 1);

        let revoked = pair_revoke_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(revoked["status"], STATUS_REVOKED);
        assert!(!is_agent_approved(&store, "codex").unwrap());
    }

    #[test]
    fn pairing_skill_cli_unpaired_skill_list_returns_pairing_required() {
        let store = test_store("unpaired");
        let result = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "pairing_required");
    }

    #[test]
    fn pairing_skill_cli_hidden_skill_returns_hidden() {
        let store = test_store("hidden");
        pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");

        skill_visibility_in(
            &store,
            &json!({"agent": "codex", "skill": "review", "hidden": true}),
        )
        .unwrap();
        let result = skill_get_in(&store, &json!({"agent": "codex", "skill": "review"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "hidden");
    }

    #[test]
    fn pairing_skill_cli_missing_skill_is_protocol_deferred() {
        let store = test_store("deferred");
        pair_request_in(
            &store,
            &json!({"agent": "codex", "target": "codex", "defaultVisibilityPolicy": "allow-all"}),
        )
        .unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();

        let result = skill_get_in(&store, &json!({"agent": "codex", "skill": "future"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "protocol_deferred");
        assert!(
            result["protocols"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item.as_str() == Some("server Skill Registry"))
        );
    }

    #[test]
    fn pairing_skill_cli_pin_and_get_are_passive() {
        let store = test_store("pin");
        pair_request_in(
            &store,
            &json!({"agent": "codex", "target": "codex", "defaultVisibilityPolicy": "allow-all"}),
        )
        .unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");

        let pinned = skill_pin_in(
            &store,
            &json!({"agent": "codex", "skill": "review", "version": "1.0.0"}),
        )
        .unwrap();
        assert_eq!(pinned["version"], "1.0.0");

        let result = skill_get_in(&store, &json!({"agent": "codex", "skill": "review"})).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["execution"], "not_supported");
        assert_eq!(result["dependencyInstall"], "not_supported");
        assert_eq!(result["copyToWorkspace"], "not_supported");
    }

    #[test]
    fn pairing_skill_hub_public_wrappers_work_with_temp_portable_state() {
        let dir = temp_test_dir("public-wrappers");
        let _guard = PortableDataDirOverrideGuard::set(dir);

        let requested = pair_request(&json!({"agent": "codex", "target": "codex"})).unwrap();
        assert_eq!(requested["status"], STATUS_REQUESTED);

        let approved = pair_approve(&json!({"agent": "codex"})).unwrap();
        assert_eq!(approved["status"], STATUS_APPROVED);

        let listed = pair_list(&json!({"agent": "codex"})).unwrap();
        assert_eq!(listed["pairings"].as_array().unwrap().len(), 1);

        let pinned =
            skill_pin(&json!({"agent": "codex", "skill": "review", "version": "0.1.0"})).unwrap();
        assert_eq!(pinned["version"], "0.1.0");

        let visibility =
            skill_visibility(&json!({"agent": "codex", "skill": "review", "hidden": "on"}))
                .unwrap();
        assert_eq!(visibility["hidden"], true);

        let list = skill_list(&json!({"agent": "codex"})).unwrap();
        assert_eq!(list["ok"], true);
    }

    #[test]
    fn pairing_skill_hub_parsing_helpers_support_aliases_and_positionals() {
        assert_eq!(
            string_param(&json!({"agentId": "codex"}), &["agent", "agentId"], 0).unwrap(),
            "codex"
        );
        assert_eq!(
            string_param(
                &json!({"positionals": ["target-id", "skill-id"]}),
                &["agent", "agentId"],
                1
            )
            .unwrap(),
            "skill-id"
        );
        assert_eq!(
            bool_param(&json!({"hidden": "hidden"}), "hidden"),
            Some(true)
        );
        assert_eq!(bool_param(&json!({"hidden": "no"}), "hidden"), Some(false));
    }

    #[test]
    fn pairing_skill_hub_upsert_policy_item_replaces_matching_visibility_entry_only() {
        let mut items = vec![
            json!({"agentId":"codex","skillId":"review","hidden":false}),
            json!({"kind":"skill","agentId":"codex","skillId":"review","hidden":false}),
        ];
        upsert_policy_item(
            &mut items,
            "codex",
            "review",
            json!({"agentId":"codex","skillId":"review","hidden":true}),
        );
        assert_eq!(items.len(), 2);
        assert_eq!(
            items
                .iter()
                .filter(|item| item.get("kind").is_none())
                .filter(|item| item.get("agentId") == Some(&json!("codex")))
                .filter(|item| item.get("skillId") == Some(&json!("review")))
                .find_map(|item| item.get("hidden").and_then(Value::as_bool)),
            Some(true)
        );
        assert_eq!(
            items
                .iter()
                .filter(|item| item.get("kind") == Some(&json!("skill")))
                .filter(|item| item.get("agentId") == Some(&json!("codex")))
                .filter(|item| item.get("skillId") == Some(&json!("review")))
                .find_map(|item| item.get("hidden").and_then(Value::as_bool)),
            Some(false)
        );
    }

    #[test]
    fn pairing_skill_cli_approve_missing_pairing_returns_error() {
        let store = test_store("approve-missing");
        let approved = pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(approved["ok"], false);
        assert_eq!(approved["error"], "pairing_not_found");
    }

    #[test]
    fn pairing_skill_cli_pin_uses_positionals_version() {
        let store = test_store("pin-positionals");
        pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");

        let pinned = skill_pin_in(
            &store,
            &json!({
                "agent": "codex",
                "skill": "review",
                "positionals": ["ignored", "2.0.0"],
            }),
        )
        .unwrap();
        assert_eq!(pinned["ok"], true);
        assert_eq!(pinned["version"], "2.0.0");
    }

    #[test]
    fn pairing_skill_hub_visibility_filters_listed_skills() {
        let store = test_store("visibility-filters-list");
        pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");
        skill_visibility_in(
            &store,
            &json!({"agent":"codex","skill":"review","hidden": "hidden"}),
        )
        .unwrap();

        let list = pair_list_in(&store, &json!({"agent":"codex"})).unwrap();
        assert_eq!(list["pairings"].as_array().unwrap().len(), 1);
        assert!(list["pairings"][0]["status"] == "approved");

        let visible = skill_list_in(&store, &json!({"agent":"codex"})).unwrap();
        assert!(visible["skills"].as_array().unwrap().is_empty());
    }

    #[test]
    fn deny_by_default_pairing_hides_unrevealed_skills() {
        let store = test_store("deny-by-default");
        pair_request_in(
            &store,
            &json!({
                "agent": "codex",
                "target": "codex",
                "defaultVisibilityPolicy": "deny-by-default"
            }),
        )
        .unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");

        let visible = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert!(visible["skills"].as_array().unwrap().is_empty());
    }

    #[test]
    fn deny_by_default_revealed_skill_is_visible() {
        let store = test_store("deny-revealed");
        pair_request_in(
            &store,
            &json!({
                "agent": "codex",
                "target": "codex",
                "defaultVisibilityPolicy": "deny-by-default"
            }),
        )
        .unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");
        skill_visibility_in(
            &store,
            &json!({
                "agent": "codex",
                "skill": "review",
                "hidden": false
            }),
        )
        .unwrap();

        let visible = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(visible["skills"].as_array().unwrap().len(), 1);
        assert_eq!(visible["skills"][0]["skillId"], "review");
    }

    #[test]
    fn allow_all_pairing_returns_unhidden_skills() {
        let store = test_store("allow-all");
        pair_request_in(
            &store,
            &json!({
                "agent": "codex",
                "target": "codex",
                "defaultVisibilityPolicy": "allow-all"
            }),
        )
        .unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");
        seed_skill(&store, "lint", "2.0.0");

        let visible = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(visible["skills"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn revoked_pairing_blocks_skill_list() {
        let store = test_store("revoked-blocks");
        pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
        pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();
        seed_skill(&store, "review", "1.0.0");
        pair_revoke_in(&store, &json!({"agent": "codex"})).unwrap();

        let result = skill_list_in(&store, &json!({"agent": "codex"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "pairing_required");
    }

    #[test]
    fn skill_install_plan_parses_github_skill_url_without_cloning() {
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

    fn installed_test_skill(name: &str, agent_id: &str) -> (ClientStateStore, PathBuf, Value) {
        let store = test_store(name);
        pair_request_in(&store, &json!({"agent": agent_id, "target": agent_id})).unwrap();
        pair_approve_in(&store, &json!({"agent": agent_id})).unwrap();
        let source_dir = create_skill_package(&format!("{name}-source"), "review-helper");
        let install_root = temp_test_dir(&format!("{name}-root"));
        let installed = skill_install_apply_in(
            &store,
            &json!({
                "agent": agent_id,
                "sourcePath": display_path(source_dir),
                "installRoot": display_path(install_root.clone())
            }),
        )
        .unwrap();
        (store, install_root, installed)
    }

    fn seed_skill(store: &ClientStateStore, skill_id: &str, version: &str) {
        let mut document = store.read_collection("skills").unwrap();
        collection_items_mut(&mut document).unwrap().push(json!({
            "kind": "skill",
            "skillId": skill_id,
            "version": version,
            "metadata": {
                "name": skill_id
            }
        }));
        store.write_collection("skills", document).unwrap();
    }

    fn test_store(name: &str) -> ClientStateStore {
        let dir: PathBuf =
            env::temp_dir().join(format!("lico-pairing-skill-{}-{}", name, timestamp()));
        fs::create_dir_all(&dir).unwrap();
        ClientStateStore::new(dir).unwrap()
    }

    struct PortableDataDirOverrideGuard {
        previous: Option<PathBuf>,
    }

    impl PortableDataDirOverrideGuard {
        fn set(path: PathBuf) -> Self {
            let previous = crate::platform::paths::set_portable_data_dir_override(Some(path));
            Self { previous }
        }
    }

    impl Drop for PortableDataDirOverrideGuard {
        fn drop(&mut self) {
            crate::platform::paths::set_portable_data_dir_override(self.previous.take());
        }
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!(
            "lico-skill-hub-{}-{}-{}",
            name,
            timestamp(),
            timestamp()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    fn create_skill_package(name: &str, skill_name: &str) -> PathBuf {
        let dir = temp_test_dir(name);
        let references = dir.join("references");
        fs::create_dir_all(&references).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!(
                "---\nname: {skill_name}\ntitle: Review Helper\ndescription: Helps review code.\nversion: 1.2.3\n---\nUse this skill for reviews.\n"
            ),
        )
        .unwrap();
        fs::write(references.join("guide.md"), "Review carefully.\n").unwrap();
        dir
    }
}
