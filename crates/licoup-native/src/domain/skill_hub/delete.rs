//! Transactional deletion of one skill from one or more selected agents.
//!
//! Planning preflights every target and binds the sorted agent set into an
//! exact confirmation. Applying quarantines all directories before removing
//! local state so a partial filesystem failure can be rolled back.

use super::{
    ClientStateStore, PathBuf, Result, Value, absolute_lexical_path, agent_id,
    directory_exists_no_follow, find_installed_skill_record, fs, is_agent_approved, json,
    recover_skill_install_journal, resolve_install_root, sanitize_skill_id, skill_id, string_param,
    uuid_v4, validate_no_symlink_ancestors,
};
use crate::platform::file_security::open_private_lock_file;
use anyhow::{anyhow, ensure};
use fs2::FileExt;
use std::collections::BTreeSet;

#[derive(Clone, Debug)]
struct DeleteTarget {
    agent_id: String,
    install_root: PathBuf,
    install_dir: PathBuf,
    exists: bool,
}

pub(super) fn plan(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let agents = agent_ids(params)?;
    let targets = delete_targets(store, params, &skill_id, &agents)?;
    let all_present = targets.iter().all(|target| target.exists);
    Ok(json!({
        "ok": true,
        "status": if all_present { "delete_planned" } else { "not_found" },
        "operation": "skill.delete",
        "skillId": skill_id,
        "agents": agents,
        "targets": targets.iter().map(summary).collect::<Vec<_>>(),
        "requiresConfirmation": true,
        "confirmation": confirmation(&skill_id, &agents),
        "deleteAllowed": all_present
    }))
}

pub(super) fn apply(store: &ClientStateStore, params: &Value) -> Result<Value> {
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let agents = agent_ids(params)?;
    require_confirmation(params, &confirmation(&skill_id, &agents))?;
    let mut targets = delete_targets(store, params, &skill_id, &agents)?;
    ensure!(
        targets.iter().all(|target| target.exists),
        "skill deletion requires every selected agent target to exist"
    );
    targets.sort_by(|left, right| {
        left.install_root
            .cmp(&right.install_root)
            .then_with(|| left.install_dir.cmp(&right.install_dir))
    });
    ensure_unique_paths(&targets)?;

    let roots = targets
        .iter()
        .map(|target| target.install_root.clone())
        .collect::<BTreeSet<_>>();
    let mut locks = Vec::with_capacity(roots.len());
    for root in &roots {
        let lock = open_private_lock_file(&root.join(".lico-skill-install.lock"))?;
        lock.lock_exclusive()?;
        recover_skill_install_journal(root)?;
        locks.push(lock);
    }

    let mut quarantined = Vec::<(PathBuf, PathBuf)>::new();
    for target in &targets {
        let quarantine = target
            .install_root
            .join(format!(".lico-skill-delete-{}", uuid_v4().replace('-', "")));
        if let Err(error) = fs::rename(&target.install_dir, &quarantine) {
            restore_quarantined(&quarantined);
            return Err(error.into());
        }
        quarantined.push((target.install_dir.clone(), quarantine));
    }

    let original_skills = store.read_collection("skills")?;
    let original_pins = store.read_collection("pins")?;
    if let Err(error) =
        remove_skill_state(store, &original_skills, &original_pins, &skill_id, &agents)
    {
        restore_quarantined(&quarantined);
        return Err(error);
    }
    for (_, quarantine) in &quarantined {
        if let Err(error) = fs::remove_dir_all(quarantine) {
            let _ = store.write_collection("skills", original_skills.clone());
            let _ = store.write_collection("pins", original_pins.clone());
            restore_quarantined(&quarantined);
            return Err(error.into());
        }
    }
    drop(locks);

    for agent_id in &agents {
        let _ = store.activity_log().append(
            "skill.deleted",
            json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id}),
        );
    }
    Ok(json!({
        "ok": true,
        "status": "deleted",
        "operation": "skill.delete",
        "skillId": skill_id,
        "agents": agents,
        "deletedCount": targets.len()
    }))
}

fn delete_targets(
    store: &ClientStateStore,
    params: &Value,
    skill_id: &str,
    agents: &[String],
) -> Result<Vec<DeleteTarget>> {
    agents
        .iter()
        .map(|agent| {
            ensure!(
                is_agent_approved(store, agent)?,
                "skill deletion requires an approved pairing for every selected agent"
            );
            resolve_target(store, params, agent, skill_id)
        })
        .collect()
}

fn resolve_target(
    store: &ClientStateStore,
    params: &Value,
    agent_id: &str,
    skill_id: &str,
) -> Result<DeleteTarget> {
    let record = find_installed_skill_record(store, agent_id, skill_id)?;
    let (install_root, install_dir) = if let Some(record) = record {
        let root = record
            .get("installRoot")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("managed skill record is missing installRoot"))?;
        let directory = record
            .get("path")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("managed skill record is missing path"))?;
        (
            absolute_lexical_path(&root)?,
            absolute_lexical_path(&directory)?,
        )
    } else {
        let request = request_for_agent(params, agent_id);
        let root = absolute_lexical_path(&resolve_install_root(agent_id, &request)?)?;
        let directory = root.join(skill_id);
        (root, directory)
    };
    ensure!(
        install_dir == install_root.join(skill_id),
        "skill target is outside the selected agent root"
    );
    validate_no_symlink_ancestors(&install_root)?;
    let exists = if directory_exists_no_follow(&install_root)? {
        validate_no_symlink_ancestors(&install_dir)?;
        directory_exists_no_follow(&install_dir)?
    } else {
        false
    };
    Ok(DeleteTarget {
        agent_id: agent_id.to_string(),
        install_root,
        install_dir,
        exists,
    })
}

fn remove_skill_state(
    store: &ClientStateStore,
    original_skills: &Value,
    original_pins: &Value,
    skill_id: &str,
    agents: &[String],
) -> Result<()> {
    let selected = agents.iter().map(String::as_str).collect::<BTreeSet<_>>();
    let mut skills = original_skills.clone();
    retain_other_records(&mut skills, skill_id, &selected);
    let mut pins = original_pins.clone();
    retain_other_records(&mut pins, skill_id, &selected);
    store.write_collection("pins", pins)?;
    if let Err(error) = store.write_collection("skills", skills) {
        let _ = store.write_collection("pins", original_pins.clone());
        return Err(error);
    }
    Ok(())
}

fn retain_other_records(document: &mut Value, skill_id: &str, agents: &BTreeSet<&str>) {
    if let Some(items) = document.get_mut("items").and_then(Value::as_array_mut) {
        items.retain(|item| {
            !(item.get("skillId").and_then(Value::as_str) == Some(skill_id)
                && item
                    .get("agentId")
                    .and_then(Value::as_str)
                    .is_some_and(|agent| agents.contains(agent)))
        });
    }
}

fn restore_quarantined(quarantined: &[(PathBuf, PathBuf)]) {
    for (target, quarantine) in quarantined.iter().rev() {
        if quarantine.exists() && !target.exists() {
            let _ = fs::rename(quarantine, target);
        }
    }
}

fn ensure_unique_paths(targets: &[DeleteTarget]) -> Result<()> {
    let mut paths = BTreeSet::new();
    for target in targets {
        ensure!(
            paths.insert(target.install_dir.clone()),
            "selected agents resolve to the same skill directory"
        );
    }
    Ok(())
}

fn summary(target: &DeleteTarget) -> Value {
    json!({"agentId": target.agent_id, "exists": target.exists})
}

fn agent_ids(params: &Value) -> Result<Vec<String>> {
    let mut agents = Vec::<String>::new();
    if let Some(values) = params.get("agents").and_then(Value::as_array) {
        agents.extend(values.iter().filter_map(Value::as_str).map(str::to_string));
    }
    if let Some(value) = params.get("agents").and_then(Value::as_str) {
        agents.extend(value.split(',').map(str::to_string));
    }
    if agents.is_empty() {
        agents.push(agent_id(params)?);
    }
    let mut unique = BTreeSet::new();
    for agent in agents {
        let trimmed = agent.trim();
        ensure!(!trimmed.is_empty(), "selected agent id is empty");
        ensure!(
            trimmed.len() <= 128
                && trimmed
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
            "selected agent id is invalid"
        );
        unique.insert(trimmed.to_string());
    }
    ensure!(!unique.is_empty(), "at least one agent must be selected");
    Ok(unique.into_iter().collect())
}

fn request_for_agent(params: &Value, agent: &str) -> Value {
    let mut request = params.clone();
    if !request.is_object() {
        request = json!({});
    }
    request["agent"] = json!(agent);
    request
}

fn require_confirmation(params: &Value, expected: &str) -> Result<()> {
    let provided = string_param(params, &["confirmation", "confirm"], usize::MAX)
        .ok_or_else(|| anyhow!("skill deletion requires its exact plan confirmation"))?;
    ensure!(
        provided == expected,
        "skill deletion confirmation does not match the selected action"
    );
    Ok(())
}

fn confirmation(skill_id: &str, agents: &[String]) -> String {
    format!("delete:{skill_id}:{}", agents.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::skill_hub::{pair_approve_in, pair_request_in, skill_install_apply_in};
    use std::{env, fs};
    use uuid::Uuid;

    #[test]
    fn one_confirmation_deletes_all_selected_agent_targets() {
        let store = test_store("multi-agent");
        let codex_root = install(&store, "codex", "codex");
        let claude_root = install(&store, "claude-code", "claude");
        let params = json!({"agents": "claude-code,codex", "skill": "review-helper"});

        let planned = plan(&store, &params).unwrap();
        assert_eq!(planned["status"], "delete_planned");
        assert_eq!(planned["agents"], json!(["claude-code", "codex"]));
        assert!(apply(&store, &params).is_err());

        let mut confirmed = params;
        confirmed["confirmation"] = planned["confirmation"].clone();
        let result = apply(&store, &confirmed).unwrap();
        assert_eq!(result["deletedCount"], 2);
        assert!(!codex_root.join("review-helper").exists());
        assert!(!claude_root.join("review-helper").exists());
    }

    #[test]
    fn plan_fails_closed_when_any_selected_target_is_missing() {
        let store = test_store("missing");
        install(&store, "codex", "present");
        pair(&store, "claude-code");
        let plan = plan(
            &store,
            &json!({"agents": "codex,claude-code", "skill": "review-helper"}),
        )
        .unwrap();
        assert_eq!(plan["status"], "not_found");
        assert_eq!(plan["deleteAllowed"], false);
    }

    fn install(store: &ClientStateStore, agent: &str, suffix: &str) -> PathBuf {
        pair(store, agent);
        let package = skill_package(&format!("package-{suffix}"));
        let root = temp_dir(&format!("root-{suffix}"));
        skill_install_apply_in(
            store,
            &json!({
                "agent": agent,
                "sourcePath": package.to_string_lossy(),
                "installRoot": root.to_string_lossy()
            }),
        )
        .unwrap();
        root
    }

    fn pair(store: &ClientStateStore, agent: &str) {
        pair_request_in(store, &json!({"agent": agent})).unwrap();
        pair_approve_in(store, &json!({"agent": agent})).unwrap();
    }

    fn skill_package(name: &str) -> PathBuf {
        let root = temp_dir(name);
        fs::write(
            root.join("SKILL.md"),
            "---\nname: review-helper\ntitle: Review Helper\nversion: 1.0.0\n---\n",
        )
        .unwrap();
        root
    }

    fn test_store(name: &str) -> ClientStateStore {
        ClientStateStore::new(temp_dir(name)).unwrap()
    }

    fn temp_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!("lico-skill-delete-{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path.canonicalize().unwrap()
    }
}
