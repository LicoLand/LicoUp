use super::super::*;

pub(super) fn installed_test_skill(
    name: &str,
    agent_id: &str,
) -> (ClientStateStore, PathBuf, Value) {
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

pub(super) fn seed_skill(store: &ClientStateStore, skill_id: &str, version: &str) {
    let mut document = store.read_collection("skills").unwrap();
    collection_items_mut(&mut document).unwrap().push(json!({
        "kind": "skill",
        "skillId": skill_id,
        "agentId": "codex",
        "version": version,
        "metadata": {
            "name": skill_id
        }
    }));
    store.write_collection("skills", document).unwrap();
}

pub(super) fn test_store(name: &str) -> ClientStateStore {
    let dir: PathBuf = env::temp_dir().join(format!("lico-pairing-skill-{}-{}", name, timestamp()));
    fs::create_dir_all(&dir).unwrap();
    ClientStateStore::new(dir).unwrap()
}

pub(super) struct PortableDataDirOverrideGuard {
    previous: Option<PathBuf>,
}

impl PortableDataDirOverrideGuard {
    pub(super) fn set(path: PathBuf) -> Self {
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(path));
        Self { previous }
    }
}

impl Drop for PortableDataDirOverrideGuard {
    fn drop(&mut self) {
        crate::platform::paths::set_portable_data_dir_override(self.previous.take());
    }
}

pub(super) fn temp_test_dir(name: &str) -> PathBuf {
    let dir = env::temp_dir().join(format!(
        "lico-skill-hub-{}-{}-{}",
        name,
        timestamp(),
        timestamp()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir.canonicalize().unwrap()
}

pub(super) fn create_skill_package(name: &str, skill_name: &str) -> PathBuf {
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
