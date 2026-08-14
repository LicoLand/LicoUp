use super::super::*;
use super::support::portable_params;
use crate::domain::agent_hub::contract::{ADAPTATION_PARTIAL, FIRST_BATCH_IDS};

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
    assert_eq!(cursor["installable"], true);
    let openclaw = cards.iter().find(|card| card["id"] == "openclaw").unwrap();
    assert_eq!(openclaw["location"], "virtual-machine");
    assert!(openclaw["connectionModes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|mode| mode == "virtual-machine"));
    for card in cards {
        assert!(card.get("binaryPath").is_none());
        assert!(card.get("configPath").is_none());
        let summary = card["summary"].as_str().unwrap();
        assert!(!summary.is_empty());
        assert!(!summary.to_lowercase().contains("rank"));
        assert!(card["homepage"]
            .as_str()
            .unwrap()
            .starts_with("https://"));
        assert!(!card["channelKind"].as_str().unwrap().is_empty());
    }
    assert_eq!(codex["channelKind"], "homebrew");
    assert_eq!(codex["homepage"], "https://developers.openai.com/codex");
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
}
