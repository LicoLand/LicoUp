use crate::client_state::ClientStateStore;
use crate::file_security::{atomic_write_private_text, ensure_private_dir};
use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
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
    let snapshot = capture_skill_install_snapshot(
        store,
        &agent_id,
        &skill_id,
        &install_dir,
        json!({
            "operation": "skill.install.apply",
            "source": source.public_summary(),
            "packageDigestSha256": preview.digest_sha256.clone()
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
    let snapshot_id = string_param(params, &["snapshotId", "snapshot"], 0)
        .ok_or_else(|| anyhow!("skill install rollback requires --snapshot-id <id>"))?;
    let snapshot_path = store
        .root()
        .join("snapshots")
        .join(format!("{snapshot_id}.json"));
    let raw = fs::read_to_string(&snapshot_path)?;
    let snapshot: Value = serde_json::from_str(&raw)?;
    if snapshot.get("kind").and_then(Value::as_str) != Some("skill-install-directory") {
        return Err(anyhow!(
            "snapshot is not a skill install directory snapshot"
        ));
    }
    let skill_id = snapshot
        .get("skillId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let install_dir = snapshot
        .get("installDir")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("snapshot is missing installDir"))?;
    restore_skill_install_snapshot(&snapshot, &install_dir)?;
    if !snapshot
        .get("existed")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        remove_installed_skill_record(store, &agent_id, &skill_id)?;
    }
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
        return Ok(PathBuf::from(root));
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
        "installDir": display_path(install_dir.to_path_buf()),
        "capturedAt": timestamp(),
        "existed": existed,
        "files": files,
        "metadata": metadata
    });
    atomic_write_private_text(
        &snapshot_path,
        &format!("{}\n", serde_json::to_string_pretty(&record)?),
    )?;
    Ok(SkillInstallSnapshot {
        snapshot_id,
        snapshot_path,
    })
}

fn restore_skill_install_snapshot(snapshot: &Value, install_dir: &Path) -> Result<()> {
    if install_dir.exists() {
        fs::remove_dir_all(install_dir)?;
    }
    if !snapshot
        .get("existed")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(());
    }
    fs::create_dir_all(install_dir)?;
    let files = snapshot
        .get("files")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("snapshot is missing files"))?;
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
        let destination = install_dir.join(relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(destination, bytes)?;
    }
    Ok(())
}

fn install_skill_dir(
    source_dir: &Path,
    install_root: &Path,
    install_dir: &Path,
    overwrite: bool,
) -> Result<()> {
    let files = collect_regular_files(source_dir)?;
    let temp_dir = install_root.join(format!(
        ".lico-skill-install-{}-tmp",
        uuid_v4().replace('-', "")
    ));
    if temp_dir.exists() {
        fs::remove_dir_all(&temp_dir)?;
    }
    fs::create_dir_all(&temp_dir)?;
    for relative in files {
        validate_relative_path(&relative)?;
        let destination = temp_dir.join(&relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(source_dir.join(&relative), destination)?;
    }
    if install_dir.exists() {
        if !overwrite {
            fs::remove_dir_all(&temp_dir)?;
            return Err(anyhow!("destination exists"));
        }
        let backup_dir = install_root.join(format!(
            ".lico-skill-install-{}-backup",
            uuid_v4().replace('-', "")
        ));
        fs::rename(install_dir, &backup_dir)?;
        fs::rename(&temp_dir, install_dir)?;
        fs::remove_dir_all(backup_dir)?;
    } else {
        fs::rename(&temp_dir, install_dir)?;
    }
    Ok(())
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
            let previous = crate::paths::set_portable_data_dir_override(Some(path));
            Self { previous }
        }
    }

    impl Drop for PortableDataDirOverrideGuard {
        fn drop(&mut self) {
            crate::paths::set_portable_data_dir_override(self.previous.take());
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
        dir
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
