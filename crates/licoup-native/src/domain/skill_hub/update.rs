//! User-confirmed updates for one managed local skill.
//!
//! Planning may fetch the selected GitHub repository so the user can review
//! an exact package plan. Applying requires the plan-bound confirmation and
//! delegates filesystem mutation to the transactional installer.

use super::{
    ClientStateStore, Result, Value, agent_id, directory_exists_no_follow,
    find_installed_skill_record, is_agent_approved, json, sanitize_skill_id, skill_id,
    skill_install_apply_in, skill_install_plan_in, string_param, validate_no_symlink_ancestors,
};
use anyhow::{anyhow, ensure};
use std::path::Path;

pub(super) fn plan(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let current = managed_skill(store, &agent_id, &skill_id)?;
    let request = request_for_skill(params, &current, &agent_id, &skill_id)?;
    let mut plan = skill_install_plan_in(store, &request)?;
    if plan.get("ok").and_then(Value::as_bool) != Some(true) {
        return Ok(plan);
    }
    let package_digest = plan
        .get("packageDigestSha256")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("skill update plan is missing its package digest"))?;
    let confirmation = confirmation(&agent_id, &skill_id, package_digest)?;
    plan["status"] = json!("update_planned");
    plan["operation"] = json!("skill.update");
    plan["requiresConfirmation"] = json!(true);
    plan["confirmation"] = json!(confirmation);
    Ok(plan)
}

pub(super) fn apply(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let agent_id = agent_id(params)?;
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let current = managed_skill(store, &agent_id, &skill_id)?;
    let expected_digest = confirmed_digest(params, &agent_id, &skill_id)?;
    let mut request = request_for_skill(params, &current, &agent_id, &skill_id)?;
    request["expectedPackageDigestSha256"] = json!(expected_digest);
    let mut result = skill_install_apply_in(store, &request)?;
    if result.get("ok").and_then(Value::as_bool) == Some(true) {
        result["status"] = json!("updated");
        result["operation"] = json!("skill.update");
    }
    Ok(result)
}

fn managed_skill(store: &ClientStateStore, agent_id: &str, skill_id: &str) -> Result<Value> {
    ensure!(
        is_agent_approved(store, agent_id)?,
        "skill update requires an approved agent pairing"
    );
    let record = find_installed_skill_record(store, agent_id, skill_id)?
        .ok_or_else(|| anyhow!("skill update requires a managed local skill"))?;
    let path = record
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("managed skill record is missing path"))?;
    validate_no_symlink_ancestors(Path::new(path))?;
    ensure!(
        directory_exists_no_follow(Path::new(path))?,
        "managed skill update target does not exist"
    );
    Ok(record)
}

fn request_for_skill(
    params: &Value,
    current: &Value,
    agent_id: &str,
    skill_id: &str,
) -> Result<Value> {
    let mut request = params.clone();
    if !request.is_object() {
        request = json!({});
    }
    request["agent"] = json!(agent_id);
    request["skill"] = json!(skill_id);
    request["name"] = json!(skill_id);
    request["overwrite"] = json!(true);
    if request.get("installRoot").is_none() {
        request["installRoot"] = current
            .get("installRoot")
            .cloned()
            .ok_or_else(|| anyhow!("managed skill record is missing installRoot"))?;
    }
    if !has_source(&request) {
        let source = current
            .pointer("/autoUpdate/source")
            .or_else(|| current.get("source"))
            .ok_or_else(|| anyhow!("managed skill record is missing update source"))?;
        bind_source(&mut request, source)?;
    }
    Ok(request)
}

fn has_source(params: &Value) -> bool {
    ["url", "githubUrl", "sourcePath", "localPath"]
        .iter()
        .any(|key| params.get(*key).is_some())
}

fn bind_source(request: &mut Value, source: &Value) -> Result<()> {
    match source.get("kind").and_then(Value::as_str) {
        Some("github") => {
            request["url"] = source
                .get("url")
                .cloned()
                .ok_or_else(|| anyhow!("configured GitHub source is missing url"))?;
            if let Some(value) = source.get("ref") {
                request["ref"] = value.clone();
            }
            if let Some(value) = source.get("path") {
                request["path"] = value.clone();
            }
        }
        Some("local-directory") => {
            request["sourcePath"] = source
                .get("path")
                .cloned()
                .ok_or_else(|| anyhow!("configured mirror source is missing path"))?;
        }
        _ => return Err(anyhow!("configured skill update source is unsupported")),
    }
    Ok(())
}

fn confirmed_digest(params: &Value, agent_id: &str, skill_id: &str) -> Result<String> {
    let provided = string_param(params, &["confirmation", "confirm"], usize::MAX)
        .ok_or_else(|| anyhow!("skill update requires its exact plan confirmation"))?;
    let prefix = format!("update:{skill_id}:{agent_id}:");
    let digest = provided
        .strip_prefix(&prefix)
        .ok_or_else(|| anyhow!("skill update confirmation does not match the selected action"))?;
    ensure!(
        is_sha256(digest),
        "skill update confirmation does not match the selected action"
    );
    Ok(digest.to_string())
}

fn confirmation(agent_id: &str, skill_id: &str, digest: &str) -> Result<String> {
    ensure!(is_sha256(digest), "skill update package digest is invalid");
    Ok(format!("update:{skill_id}:{agent_id}:{digest}"))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::skill_hub::{pair_approve_in, pair_request_in, skill_install_apply_in};
    use std::{env, fs, path::PathBuf};
    use uuid::Uuid;

    #[test]
    fn plan_bound_confirmation_controls_transactional_update() {
        let store = test_store("update");
        pair(&store, "codex");
        let root = temp_dir("update-root");
        let original = skill_package("update-original", "original\n");
        skill_install_apply_in(
            &store,
            &json!({
                "agent": "codex",
                "sourcePath": original.to_string_lossy(),
                "installRoot": root.to_string_lossy()
            }),
        )
        .unwrap();
        let replacement = skill_package("update-replacement", "replacement\n");
        let params = json!({
            "agent": "codex",
            "skill": "review-helper",
            "sourcePath": replacement.to_string_lossy(),
            "installRoot": root.to_string_lossy()
        });

        let planned = plan(&store, &params).unwrap();
        assert_eq!(planned["status"], "update_planned");
        assert!(apply(&store, &params).is_err());

        let mut confirmed = params;
        confirmed["confirmation"] = planned["confirmation"].clone();
        fs::write(
            replacement.join("references/guide.md"),
            "changed after review\n",
        )
        .unwrap();
        assert!(apply(&store, &confirmed).is_err());
        fs::write(replacement.join("references/guide.md"), "replacement\n").unwrap();
        let result = apply(&store, &confirmed).unwrap();
        assert_eq!(result["status"], "updated");
        assert_eq!(
            fs::read_to_string(root.join("review-helper/references/guide.md")).unwrap(),
            "replacement\n"
        );
    }

    fn pair(store: &ClientStateStore, agent: &str) {
        pair_request_in(store, &json!({"agent": agent})).unwrap();
        pair_approve_in(store, &json!({"agent": agent})).unwrap();
    }

    fn skill_package(name: &str, guide: &str) -> PathBuf {
        let root = temp_dir(name);
        fs::create_dir_all(root.join("references")).unwrap();
        fs::write(
            root.join("SKILL.md"),
            "---\nname: review-helper\ntitle: Review Helper\nversion: 1.0.0\n---\n",
        )
        .unwrap();
        fs::write(root.join("references/guide.md"), guide).unwrap();
        root
    }

    fn test_store(name: &str) -> ClientStateStore {
        ClientStateStore::new(temp_dir(name)).unwrap()
    }

    fn temp_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!("lico-skill-update-{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path.canonicalize().unwrap()
    }
}
