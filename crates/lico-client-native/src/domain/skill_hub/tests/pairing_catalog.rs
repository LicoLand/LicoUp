use super::super::*;
use super::support::*;

#[test]
fn pairing_skill_cli_pair_request_approve_revoke_list() {
    let store = test_store("pairing-lifecycle");
    let requested = pair_request_in(&store, &json!({"agent": "codex", "target": "codex"})).unwrap();
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
fn pairing_skill_cli_missing_local_skill_is_not_found() {
    let store = test_store("not-found");
    pair_request_in(
        &store,
        &json!({"agent": "codex", "target": "codex", "defaultVisibilityPolicy": "allow-all"}),
    )
    .unwrap();
    pair_approve_in(&store, &json!({"agent": "codex"})).unwrap();

    let result = skill_get_in(&store, &json!({"agent": "codex", "skill": "future"})).unwrap();
    assert_eq!(result["ok"], false);
    assert_eq!(result["error"], "not_found");
    assert_eq!(result["source"], "local-agent-skill-roots");
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
        skill_visibility(&json!({"agent": "codex", "skill": "review", "hidden": "on"})).unwrap();
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
