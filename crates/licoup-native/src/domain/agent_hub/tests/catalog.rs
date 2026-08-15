use super::super::*;
use super::support::portable_params;
use crate::domain::agent_hub::contract::{
    ADAPTATION_PARTIAL, FIRST_BATCH_IDS, InstallOwnership, LIFECYCLE_AVAILABLE, OWNERSHIP_OWNED,
};
use crate::domain::agent_hub::ownership;
use crate::platform::client_state::ClientStateStore;

#[test]
fn catalog_joins_one_discovery_snapshot_onto_eight_cards() {
    let mut params = portable_params("catalog").1;
    params["discoveryCandidates"] = serde_json::json!([
        {
            "target": "codex",
            "status": "detected",
            "present": true,
            "location": "local",
            "scanSource": "package-manager"
        },
        {
            "target": "openclaw",
            "status": "detected",
            "present": true,
            "location": "virtual-machine",
            "scanSource": "virtual-machine-orbstack"
        }
    ]);
    let catalog = catalog(&params).unwrap();
    assert_eq!(catalog["scanGeneration"], 7);
    assert_eq!(catalog["pluginManagementBoundary"], "adapter-plugins-only");
    let cards = catalog["cards"].as_array().unwrap();
    assert_eq!(cards.len(), FIRST_BATCH_IDS.len());
    let ids = cards
        .iter()
        .map(|card| card["id"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(ids, FIRST_BATCH_IDS);
    let antigravity = cards
        .iter()
        .find(|card| card["id"] == "antigravity")
        .unwrap();
    assert_eq!(antigravity["adaptation"], ADAPTATION_PARTIAL);
    let codex = cards.iter().find(|card| card["id"] == "codex").unwrap();
    assert_eq!(codex["ownership"], "external");
    assert_eq!(codex["installable"], false);
    assert_eq!(codex["primaryAction"], "open");
    let cursor = cards.iter().find(|card| card["id"] == "cursor").unwrap();
    assert_eq!(cursor["adaptation"], "deep");
    assert_eq!(cursor["installable"], false);
    assert_eq!(cursor["primaryAction"], "install");
    assert_eq!(cursor["channelKind"], "");
    assert!(cursor["installChannels"].as_array().unwrap().is_empty());
    let openclaw = cards.iter().find(|card| card["id"] == "openclaw").unwrap();
    assert_eq!(openclaw["location"], "virtual-machine");
    assert!(
        openclaw["connectionModes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|mode| mode == "virtual-machine")
    );
    for card in cards {
        assert!(card.get("binaryPath").is_none());
        assert!(card.get("configPath").is_none());
        let summary = card["summary"].as_str().unwrap();
        assert!(!summary.is_empty());
        assert!(!summary.to_lowercase().contains("rank"));
        assert!(card["homepage"].as_str().unwrap().starts_with("https://"));
        assert_eq!(card["channelKind"], "");
        assert!(card["installChannels"].as_array().unwrap().is_empty());
    }
    assert_eq!(codex["homepage"], "https://developers.openai.com/codex");
    assert_eq!(codex["version"], "");
    assert_eq!(codex["installedVersion"], "");
    assert_eq!(codex["latestVersion"], "");
    assert_eq!(codex["updateAvailable"], false);
}

#[test]
fn catalog_with_agent_id_loads_that_agent_toml() {
    let mut params = portable_params("agent-toml").1;
    params["agentId"] = serde_json::json!("cursor");
    params["discoveryCandidates"] = serde_json::json!([]);
    let catalog = catalog(&params).unwrap();
    let cards = catalog["cards"].as_array().unwrap();
    assert_eq!(cards.len(), 1);
    let cursor = &cards[0];
    assert_eq!(cursor["id"], "cursor");
    assert_eq!(cursor["installable"], true);
    assert_eq!(cursor["channelKind"], "homebrew");
    let channels = cursor["installChannels"].as_array().unwrap();
    assert!(channels.iter().any(|channel| channel["id"] == "homebrew"));
    assert!(channels.iter().all(|channel| channel["kind"] != "npm"));
    assert!(
        channels
            .iter()
            .all(|channel| channel.get("installArgv").is_none())
    );
    let homebrew = channels
        .iter()
        .find(|channel| channel["id"] == "homebrew")
        .unwrap();
    assert_eq!(homebrew["officialSource"], "https://downloads.cursor.com");
    assert_eq!(homebrew["commandPreview"], "brew install --cask cursor-cli");
}

#[test]
fn catalog_does_not_emit_install_actions_for_missing_channels() {
    let mut params = portable_params("no-channel").1;
    params["platformCapabilities"] = serde_json::json!({
        "os": "windows",
        "architecture": "x86_64",
        "managers": ["npm"],
        "scanGeneration": 2
    });
    params["discoveryCandidates"] = serde_json::json!([]);
    params["agentId"] = serde_json::json!("hermes");
    let catalog = catalog(&params).unwrap();
    let hermes = catalog["cards"]
        .as_array()
        .unwrap()
        .iter()
        .find(|card| card["id"] == "hermes")
        .unwrap();
    assert_eq!(hermes["installable"], false);
    assert_eq!(hermes["primaryAction"], "unsupported");
    assert_eq!(hermes["channelKind"], "official-artifact");
    assert!(hermes["selectedChannelKind"].is_null());
    assert_eq!(hermes["version"], "");
    assert_eq!(hermes["updateAvailable"], false);
    assert!(hermes["installChannels"].as_array().unwrap().is_empty());
}

fn present_codex(params: &mut serde_json::Value) {
    params["discoveryCandidates"] = serde_json::json!([
        {
            "target": "codex",
            "status": "detected",
            "present": true,
            "location": "local"
        }
    ]);
}

fn card<'a>(catalog: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    catalog["cards"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == id)
        .unwrap()
}

#[test]
fn catalog_marks_update_available_when_latest_is_strictly_newer() {
    let mut params = portable_params("newer").1;
    present_codex(&mut params);
    params["packageMetadata"] = serde_json::json!({
        "codex": {
            "installedVersion": "0.42.1",
            "latestVersion": "0.43.0"
        }
    });
    let catalog = catalog(&params).unwrap();
    let codex = card(&catalog, "codex");
    assert_eq!(codex["installedVersion"], "0.42.1");
    assert_eq!(codex["latestVersion"], "0.43.0");
    assert_eq!(codex["version"], "0.42.1");
    assert_eq!(codex["updateAvailable"], true);
}

#[test]
fn catalog_does_not_mark_update_when_versions_are_equal() {
    let mut params = portable_params("equal").1;
    present_codex(&mut params);
    params["packageMetadata"] = serde_json::json!({
        "codex": {
            "installedVersion": "0.42.1",
            "latestVersion": "0.42.1"
        }
    });
    let catalog = catalog(&params).unwrap();
    let codex = card(&catalog, "codex");
    assert_eq!(codex["installedVersion"], "0.42.1");
    assert_eq!(codex["latestVersion"], "0.42.1");
    assert_eq!(codex["updateAvailable"], false);
}

#[test]
fn catalog_does_not_mark_update_when_versions_are_missing() {
    let mut params = portable_params("missing").1;
    present_codex(&mut params);
    let catalog = catalog(&params).unwrap();
    let codex = card(&catalog, "codex");
    assert_eq!(codex["installedVersion"], "");
    assert_eq!(codex["latestVersion"], "");
    assert_eq!(codex["updateAvailable"], false);
}

#[test]
fn catalog_does_not_mark_update_when_versions_are_unparseable() {
    let mut params = portable_params("unparseable").1;
    present_codex(&mut params);
    params["packageMetadata"] = serde_json::json!({
        "codex": {
            "installedVersion": "latest",
            "latestVersion": "vendor-latest"
        }
    });
    let catalog = catalog(&params).unwrap();
    let codex = card(&catalog, "codex");
    assert_eq!(codex["installedVersion"], "");
    assert_eq!(codex["latestVersion"], "");
    assert_eq!(codex["updateAvailable"], false);
}

#[test]
fn catalog_prefers_owned_installed_version_over_the_word_latest() {
    let (dir, mut params) = portable_params("owned-version");
    present_codex(&mut params);
    let store = ClientStateStore::new(dir.join("client-state")).unwrap();
    ownership::save(
        &store,
        InstallOwnership {
            agent_id: "codex".to_string(),
            channel_id: "homebrew".to_string(),
            channel_kind: "homebrew".to_string(),
            package_coordinate: "codex".to_string(),
            installed_version: "0.41.0".to_string(),
            ownership: OWNERSHIP_OWNED.to_string(),
            lifecycle: LIFECYCLE_AVAILABLE.to_string(),
        },
    )
    .unwrap();
    params["packageMetadata"] = serde_json::json!({
        "codex": { "latestVersion": "0.42.1" }
    });
    let catalog = catalog(&params).unwrap();
    let codex = card(&catalog, "codex");
    assert_eq!(codex["installedVersion"], "0.41.0");
    assert_eq!(codex["latestVersion"], "0.42.1");
    assert_eq!(codex["version"], "0.41.0");
    assert_eq!(codex["updateAvailable"], true);
}

#[test]
fn catalog_uses_dedicated_version_probes_and_keeps_absent_cards_blank() {
    let mut params = portable_params("probes").1;
    params["discoveryCandidates"] = serde_json::json!([
        { "target": "codex", "present": true, "location": "local" },
        { "target": "cursor", "present": true, "location": "local" }
    ]);
    params["versionProbes"] = serde_json::json!({
        "codex": "codex-cli 0.147.0",
        "cursor": "cursor-agent 1.4.2",
        "opencode": "1.0.0"
    });
    params["packageMetadata"] = serde_json::json!({
        "opencode": { "installedVersion": "9.9.9" }
    });
    let catalog = catalog(&params).unwrap();
    assert_eq!(card(&catalog, "codex")["installedVersion"], "0.147.0");
    assert_eq!(card(&catalog, "cursor")["installedVersion"], "1.4.2");
    assert_eq!(card(&catalog, "opencode")["installedVersion"], "");
    assert_eq!(card(&catalog, "claude-code")["installedVersion"], "");
    assert_eq!(card(&catalog, "opencode")["version"], "");
    for item in catalog["cards"].as_array().unwrap() {
        let version = item["installedVersion"].as_str().unwrap();
        assert_ne!(version, "unknown");
        assert_ne!(version, "未知");
    }
}

#[test]
fn catalog_without_live_lookup_is_a_static_eight_card_template() {
    let mut params = portable_params("static-template").1;
    params
        .as_object_mut()
        .unwrap()
        .remove("discoveryCandidates");
    let catalog = catalog(&params).unwrap();
    let cards = catalog["cards"].as_array().unwrap();
    assert_eq!(cards.len(), FIRST_BATCH_IDS.len());
    for item in cards {
        assert_eq!(item["installedVersion"], "");
        assert_eq!(item["latestVersion"], "");
        assert_eq!(item["updateAvailable"], false);
        assert_eq!(item["present"], false);
        assert!(!item["label"].as_str().unwrap().is_empty());
        assert!(!item["summary"].as_str().unwrap().is_empty());
    }
}

#[test]
fn catalog_with_agent_id_projects_one_injected_card() {
    let mut params = portable_params("one-card").1;
    present_codex(&mut params);
    params["agentId"] = serde_json::json!("codex");
    params["versionProbes"] = serde_json::json!({
        "codex": "codex-cli 0.147.0"
    });
    let catalog = catalog(&params).unwrap();
    let cards = catalog["cards"].as_array().unwrap();
    assert_eq!(cards.len(), 1);
    assert_eq!(cards[0]["id"], "codex");
    assert_eq!(cards[0]["present"], true);
    assert_eq!(cards[0]["installedVersion"], "0.147.0");
}

#[test]
fn catalog_rejects_unknown_agent_id() {
    let mut params = portable_params("unknown-id").1;
    params["agentId"] = serde_json::json!("not-an-agent");
    let error = catalog(&params).unwrap_err();
    assert!(error.to_string().contains("recipe_not_found"));
}
