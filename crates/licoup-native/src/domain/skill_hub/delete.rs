//! Recoverable removal of one catalog skill directory.
//!
//! Planning validates the exact local skill package and binds both its path and
//! content digest into the confirmation. Applying moves the directory to the
//! operating system's Trash or Recycle Bin; it never permanently removes the
//! skill directory.

use super::{
    ClientStateStore, Path, PathBuf, Result, Value, absolute_lexical_path,
    directory_exists_no_follow, home_dir, inspect_skill_dir, is_path_inside, json,
    sanitize_skill_id, skill_id, string_param, validate_no_symlink_ancestors,
};
use anyhow::{anyhow, ensure};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, env};

const CATALOG_ROOT_PATTERNS: &[&[&str]] = &[
    &[".config", "agents", "skills"],
    &[".config", "opencode", "skills"],
    &[".gemini", "antigravity", "builtin", "skills"],
    &[".gemini", "config", "skills"],
    &[".agents", "skills"],
    &["content", "skills"],
    &[".claude", "skills"],
    &[".codex", "skills"],
    &[".github", "skills"],
    &[".copilot", "skills"],
    &[".cursor", "skills"],
    &[".opencode", "skills"],
    &[".kilo", "skills"],
    &[".kimi", "skills"],
    &[".openclaw", "skills"],
];

#[derive(Clone, Debug)]
struct DeleteTarget {
    install_dir: PathBuf,
    exists: bool,
    package_digest: String,
}

pub(super) fn plan(_store: &ClientStateStore, params: &Value) -> Result<Value> {
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let target = resolve_target(params, &skill_id)?;
    let allowed = target.exists;
    let confirmation = confirmation(&skill_id, &target);
    Ok(json!({
        "ok": true,
        "status": if allowed { "trash_planned" } else { "not_found" },
        "operation": "skill.trash",
        "skillId": skill_id,
        "target": summary(&target),
        "requiresConfirmation": true,
        "confirmation": confirmation,
        "trashAllowed": allowed
    }))
}

pub(super) fn apply(store: &ClientStateStore, params: &Value) -> Result<Value> {
    apply_with_trash(store, params, move_to_system_trash)
}

fn apply_with_trash<F>(store: &ClientStateStore, params: &Value, move_to_trash: F) -> Result<Value>
where
    F: FnOnce(&Path) -> Result<()>,
{
    let skill_id = sanitize_skill_id(&skill_id(params)?)?;
    let target = resolve_target(params, &skill_id)?;
    require_confirmation(params, &confirmation(&skill_id, &target))?;
    ensure!(
        target.exists,
        "skill trash requires the selected catalog target to exist"
    );

    let original_skills = store.read_collection("skills")?;
    let original_pins = store.read_collection("pins")?;
    let affected_agents = remove_skill_state(
        store,
        &original_skills,
        &original_pins,
        &skill_id,
        &target.install_dir,
    )?;
    if let Err(error) = move_to_trash(&target.install_dir) {
        let _ = store.write_collection("skills", original_skills);
        let _ = store.write_collection("pins", original_pins);
        return Err(error);
    }
    if affected_agents.is_empty() {
        let _ = store.activity_log().append(
            "skill.trashed",
            json!({"target": "local-catalog", "skillId": skill_id}),
        );
    } else {
        for agent_id in &affected_agents {
            let _ = store.activity_log().append(
                "skill.trashed",
                json!({"target": agent_id, "agentId": agent_id, "skillId": skill_id}),
            );
        }
    }
    Ok(json!({
        "ok": true,
        "status": "trashed",
        "operation": "skill.trash",
        "skillId": skill_id,
        "trashedCount": 1
    }))
}

fn resolve_target(params: &Value, skill_id: &str) -> Result<DeleteTarget> {
    let requested_path = string_param(params, &["path"], usize::MAX)
        .ok_or_else(|| anyhow!("skill trash requires an exact catalog path"))?;
    let install_dir = absolute_lexical_path(Path::new(&requested_path))?;
    trusted_catalog_root(&install_dir)?;
    validate_no_symlink_ancestors(&install_dir)?;
    let exists = directory_exists_no_follow(&install_dir)?;
    let package_digest = if exists {
        let preview = inspect_skill_dir(&install_dir)?;
        ensure!(
            preview.skill_id == skill_id,
            "skill path does not match the selected catalog skill"
        );
        preview.digest_sha256
    } else {
        String::new()
    };
    Ok(DeleteTarget {
        install_dir,
        exists,
        package_digest,
    })
}

fn trusted_catalog_root(path: &Path) -> Result<PathBuf> {
    let catalog_root = recognized_catalog_root(path)
        .ok_or_else(|| anyhow!("skill path is outside a recognized catalog root"))?;
    let workspace_root = absolute_lexical_path(&env::current_dir()?)?;
    let within_workspace =
        workspace_root.parent().is_some() && is_path_inside(&workspace_root, &catalog_root);
    let within_home = home_dir()
        .and_then(|root| absolute_lexical_path(&root).ok())
        .is_some_and(|root| is_path_inside(&root, &catalog_root));
    ensure!(
        within_workspace || within_home,
        "skill path is outside the local Skill Hub scan roots"
    );
    Ok(catalog_root)
}

fn recognized_catalog_root(path: &Path) -> Option<PathBuf> {
    let components = path.components().collect::<Vec<_>>();
    let normalized = components
        .iter()
        .map(|component| component.as_os_str().to_string_lossy().to_ascii_lowercase())
        .collect::<Vec<_>>();
    let mut closest_root_end = None::<usize>;
    for start in 0..normalized.len() {
        for pattern in CATALOG_ROOT_PATTERNS {
            let end = start.saturating_add(pattern.len());
            if end >= normalized.len() {
                continue;
            }
            if normalized[start..end]
                .iter()
                .map(String::as_str)
                .eq(pattern.iter().copied())
            {
                closest_root_end = Some(closest_root_end.map_or(end, |current| current.max(end)));
            }
        }
    }
    let end = closest_root_end?;
    let mut root = PathBuf::new();
    for component in components.iter().take(end) {
        root.push(component.as_os_str());
    }
    Some(root)
}

fn remove_skill_state(
    store: &ClientStateStore,
    original_skills: &Value,
    original_pins: &Value,
    skill_id: &str,
    install_dir: &Path,
) -> Result<BTreeSet<String>> {
    let affected_agents = affected_agents_for_path(original_skills, skill_id, install_dir);
    if affected_agents.is_empty() {
        return Ok(affected_agents);
    }

    let mut skills = original_skills.clone();
    retain_other_records(&mut skills, skill_id, &affected_agents);
    let mut pins = original_pins.clone();
    retain_other_records(&mut pins, skill_id, &affected_agents);
    store.write_collection("pins", pins)?;
    if let Err(error) = store.write_collection("skills", skills) {
        let _ = store.write_collection("pins", original_pins.clone());
        return Err(error);
    }
    Ok(affected_agents)
}

fn affected_agents_for_path(
    document: &Value,
    skill_id: &str,
    install_dir: &Path,
) -> BTreeSet<String> {
    document
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| item.get("kind").and_then(Value::as_str) == Some("skill"))
        .filter(|item| item.get("skillId").and_then(Value::as_str) == Some(skill_id))
        .filter(|item| record_path_matches(item, install_dir))
        .filter_map(|item| item.get("agentId").and_then(Value::as_str))
        .map(str::to_string)
        .collect()
}

fn record_path_matches(item: &Value, install_dir: &Path) -> bool {
    let Some(path) = item.get("path").and_then(Value::as_str) else {
        return false;
    };
    absolute_lexical_path(Path::new(path)).is_ok_and(|resolved| resolved == install_dir)
}

fn retain_other_records(document: &mut Value, skill_id: &str, agents: &BTreeSet<String>) {
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

fn move_to_system_trash(path: &Path) -> Result<()> {
    trash::delete(path).map_err(|_| anyhow!("moving skill to system trash failed"))
}

fn summary(target: &DeleteTarget) -> Value {
    json!({"exists": target.exists})
}

fn require_confirmation(params: &Value, expected: &str) -> Result<()> {
    let provided = string_param(params, &["confirmation", "confirm"], usize::MAX)
        .ok_or_else(|| anyhow!("skill trash requires its exact plan confirmation"))?;
    ensure!(
        provided == expected,
        "skill trash confirmation does not match the selected action"
    );
    Ok(())
}

fn confirmation(skill_id: &str, target: &DeleteTarget) -> String {
    let mut digest = Sha256::new();
    digest.update(target.install_dir.to_string_lossy().as_bytes());
    digest.update([0]);
    digest.update(target.package_digest.as_bytes());
    let encoded = digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("trash:{skill_id}:{encoded}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use uuid::Uuid;

    #[test]
    fn exact_confirmation_moves_catalog_skill_to_recoverable_trash() {
        let store = test_store("recoverable");
        let catalog_root = catalog_root("recoverable");
        let skill_dir = skill_package(&catalog_root, "review-helper-folder");
        let recycle_root = temp_dir("recycle");
        let params = json!({
            "skill": "review-helper",
            "path": skill_dir.to_string_lossy()
        });

        let planned = plan(&store, &params).unwrap();
        assert_eq!(planned["status"], "trash_planned");
        assert_eq!(planned["trashAllowed"], true);
        assert!(apply_with_trash(&store, &params, |_| Ok(())).is_err());

        let mut confirmed = params;
        confirmed["confirmation"] = planned["confirmation"].clone();
        let recycled = recycle_root.join("review-helper-folder");
        let result = apply_with_trash(&store, &confirmed, |source| {
            fs::rename(source, &recycled)?;
            Ok(())
        })
        .unwrap();
        assert_eq!(result["status"], "trashed");
        assert_eq!(result["trashedCount"], 1);
        assert!(!skill_dir.exists());
        assert!(recycled.join("SKILL.md").is_file());
    }

    #[test]
    fn plan_rejects_skill_packages_outside_recognized_catalog_roots() {
        let store = test_store("outside");
        let root = temp_dir("outside-package");
        let skill_dir = skill_package(&root, "review-helper-folder");
        let result = plan(
            &store,
            &json!({
                "skill": "review-helper",
                "path": skill_dir.to_string_lossy()
            }),
        );
        assert!(result.is_err());
        assert!(skill_dir.exists());
    }

    #[test]
    #[cfg(not(windows))]
    fn plan_rejects_recognized_catalog_paths_outside_local_scan_roots() {
        let store = test_store("untrusted-root");
        let root = system_temp_dir("untrusted-root")
            .join(".agents")
            .join("skills");
        fs::create_dir_all(&root).unwrap();
        let skill_dir = skill_package(&root, "review-helper-folder");
        let result = plan(
            &store,
            &json!({
                "skill": "review-helper",
                "path": skill_dir.to_string_lossy()
            }),
        );
        assert!(result.is_err());
        assert!(skill_dir.exists());
    }

    #[test]
    fn confirmation_is_invalidated_when_skill_contents_change() {
        let store = test_store("changed");
        let catalog_root = catalog_root("changed");
        let skill_dir = skill_package(&catalog_root, "review-helper-folder");
        let mut params = json!({
            "skill": "review-helper",
            "path": skill_dir.to_string_lossy()
        });
        let planned = plan(&store, &params).unwrap();
        params["confirmation"] = planned["confirmation"].clone();
        fs::write(skill_dir.join("notes.txt"), "changed after planning").unwrap();

        assert!(apply_with_trash(&store, &params, |_| Ok(())).is_err());
        assert!(skill_dir.exists());
    }

    fn catalog_root(name: &str) -> PathBuf {
        let root = temp_dir(name).join(".agents").join("skills");
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn skill_package(catalog_root: &Path, directory_name: &str) -> PathBuf {
        let root = catalog_root.join(directory_name);
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("SKILL.md"),
            "---\nname: review-helper\ntitle: Review Helper\nversion: 1.0.0\n---\n",
        )
        .unwrap();
        root
    }

    fn test_store(name: &str) -> ClientStateStore {
        ClientStateStore::new(temp_dir(&format!("state-{name}"))).unwrap()
    }

    fn temp_dir(name: &str) -> PathBuf {
        let path = env::current_dir()
            .unwrap()
            .join("target")
            .join("skill-trash-tests")
            .join(format!("{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path.canonicalize().unwrap()
    }

    fn system_temp_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!("lico-skill-trash-{name}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path.canonicalize().unwrap()
    }
}
