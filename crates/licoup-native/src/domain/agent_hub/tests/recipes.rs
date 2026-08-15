use super::super::*;
use crate::domain::agent_hub::argv::{self, ArgvKind};
use crate::domain::agent_hub::contract::{
    ADAPTATION_DEEP, ADAPTATION_PARTIAL, ADAPTATION_PENDING, FIRST_BATCH_IDS,
    PARTIAL_ADAPTATION_ID, PENDING_ADAPTATION_ID,
};
use crate::domain::agent_hub::recipes::{manifest, parse_agent_toml, parse_manifest};
use crate::domain::agent_hub::selector;
use serde_json::json;

#[test]
fn first_batch_recipes_load_with_fixed_ids_and_adaptation_tags() {
    let registry = registry().unwrap();
    let ids = registry
        .agents
        .iter()
        .map(|agent| agent.id.as_str())
        .collect::<Vec<_>>();
    assert_eq!(ids, FIRST_BATCH_IDS);
    for agent in &registry.agents {
        if agent.id == PARTIAL_ADAPTATION_ID {
            assert_eq!(agent.adaptation, ADAPTATION_PARTIAL);
        } else if agent.id == PENDING_ADAPTATION_ID {
            assert_eq!(agent.adaptation, ADAPTATION_PENDING);
        } else {
            assert_eq!(agent.adaptation, ADAPTATION_DEEP);
        }
        assert!(agent.summary.contains(' '));
        assert!(!agent.summary.to_lowercase().contains("rank #"));
        assert!(agent.homepage.starts_with("https://"));
        let kinds = agent
            .channels
            .iter()
            .map(|channel| channel.kind.as_str())
            .collect::<Vec<_>>();
        assert!(kinds.contains(&"homebrew"));
        assert!(kinds.contains(&"npm"));
        assert!(kinds.contains(&"winget") || agent.id == "hermes");
        assert!(kinds.contains(&"official-artifact") || agent.id == "pi");
    }
    let cursor = registry
        .agents
        .iter()
        .find(|agent| agent.id == "cursor")
        .unwrap();
    let cursor_kinds = cursor
        .channels
        .iter()
        .map(|channel| channel.kind.as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        cursor_kinds,
        vec!["homebrew", "npm", "winget", "official-artifact"]
    );
    assert_eq!(cursor.binary_names, vec!["cursor-agent"]);
    let openclaw = registry
        .agents
        .iter()
        .find(|agent| agent.id == "openclaw")
        .unwrap();
    assert!(openclaw.connection_modes.contains(&"local".to_string()));
    assert!(
        openclaw
            .connection_modes
            .contains(&"virtual-machine".to_string())
    );
    let hermes = registry
        .agents
        .iter()
        .find(|agent| agent.id == "hermes")
        .unwrap();
    assert!(
        hermes
            .connection_modes
            .contains(&"virtual-machine".to_string())
    );
}

#[test]
fn warehouse_is_one_manifest_and_one_toml_per_agent() {
    let loaded = manifest().unwrap();
    assert_eq!(
        loaded.schema_version,
        crate::domain::agent_hub::SCHEMA_VERSION
    );
    assert_eq!(
        loaded
            .agents
            .iter()
            .map(|agent| agent.file.as_str())
            .collect::<Vec<_>>(),
        vec![
            "codex.toml",
            "cursor.toml",
            "opencode.toml",
            "claude-code.toml",
            "pi.toml",
            "openclaw.toml",
            "hermes.toml",
            "antigravity.toml",
            "deepseek-harness.toml",
        ]
    );
    parse_manifest(include_str!(
        "../../../../resources/agent-hub/manifest.toml"
    ))
    .unwrap();
    for agent in &loaded.agents {
        let raw = match agent.id.as_str() {
            "codex" => include_str!("../../../../resources/agent-hub/codex.toml"),
            "cursor" => include_str!("../../../../resources/agent-hub/cursor.toml"),
            "opencode" => include_str!("../../../../resources/agent-hub/opencode.toml"),
            "claude-code" => include_str!("../../../../resources/agent-hub/claude-code.toml"),
            "pi" => include_str!("../../../../resources/agent-hub/pi.toml"),
            "openclaw" => include_str!("../../../../resources/agent-hub/openclaw.toml"),
            "hermes" => include_str!("../../../../resources/agent-hub/hermes.toml"),
            "antigravity" => include_str!("../../../../resources/agent-hub/antigravity.toml"),
            "deepseek-harness" => {
                include_str!("../../../../resources/agent-hub/deepseek-harness.toml")
            }
            other => panic!("unexpected agent {other}"),
        };
        let document = parse_agent_toml(raw).unwrap();
        assert_eq!(document.id, agent.id);
        assert!(!document.channels.is_empty());
    }
}

#[test]
fn recipes_are_argv_only_official_https_and_never_pipe_to_shell() {
    let sources = [
        include_str!("../../../../resources/agent-hub/codex.toml"),
        include_str!("../../../../resources/agent-hub/cursor.toml"),
        include_str!("../../../../resources/agent-hub/opencode.toml"),
        include_str!("../../../../resources/agent-hub/claude-code.toml"),
        include_str!("../../../../resources/agent-hub/pi.toml"),
        include_str!("../../../../resources/agent-hub/openclaw.toml"),
        include_str!("../../../../resources/agent-hub/hermes.toml"),
        include_str!("../../../../resources/agent-hub/antigravity.toml"),
        include_str!("../../../../resources/agent-hub/deepseek-harness.toml"),
    ];
    for raw in sources {
        assert!(!raw.contains("curl|"));
        assert!(!raw.contains("| sh"));
        assert!(!raw.contains("| bash"));
        assert!(!raw.contains("| iex"));
    }
    let registry = registry().unwrap();
    for agent in &registry.agents {
        for channel in &agent.channels {
            assert!(channel.official_source.starts_with("https://"));
            for argv in [
                &channel.install_argv,
                &channel.windows_install_argv,
                &channel.update_argv,
                &channel.uninstall_argv,
                &channel.verify_argv,
            ] {
                argv::validate(argv, ArgvKind::for_channel(&channel.kind)).unwrap();
                let joined = argv.join(" ");
                assert!(!joined.contains('|'));
                assert!(!joined.contains(" -c "));
            }
        }
    }
}

#[test]
fn each_desktop_os_selects_one_stable_channel_from_capability_snapshot() {
    let registry = registry().unwrap();
    let cases = [
        (
            "macos",
            "aarch64",
            &["homebrew", "npm"][..],
            "codex",
            "homebrew",
        ),
        ("macos", "aarch64", &["npm"][..], "codex", "npm"),
        (
            "windows",
            "x86_64",
            &["winget", "npm"][..],
            "codex",
            "winget",
        ),
        ("linux", "x86_64", &["npm"][..], "codex", "npm"),
        ("macos", "aarch64", &[][..], "codex", "official-artifact"),
        ("macos", "aarch64", &["homebrew"][..], "cursor", "homebrew"),
        ("linux", "aarch64", &[][..], "cursor", "official-artifact"),
        (
            "macos",
            "aarch64",
            &["homebrew", "npm"][..],
            "opencode",
            "homebrew",
        ),
        (
            "macos",
            "aarch64",
            &["homebrew", "npm"][..],
            "claude-code",
            "homebrew",
        ),
        (
            "windows",
            "x86_64",
            &["winget"][..],
            "claude-code",
            "winget",
        ),
        ("linux", "x86_64", &["npm"][..], "pi", "npm"),
        ("macos", "aarch64", &["homebrew", "npm"][..], "pi", "npm"),
        ("macos", "aarch64", &["npm"][..], "openclaw", "npm"),
        ("linux", "aarch64", &[][..], "hermes", "official-artifact"),
        (
            "macos",
            "aarch64",
            &["homebrew"][..],
            "antigravity",
            "homebrew",
        ),
        (
            "linux",
            "x86_64",
            &[][..],
            "antigravity",
            "official-artifact",
        ),
        (
            "macos",
            "aarch64",
            &["homebrew", "npm"][..],
            "deepseek-harness",
            "npm",
        ),
        ("linux", "x86_64", &["npm"][..], "deepseek-harness", "npm"),
    ];
    for (os, arch, managers, agent_id, expected) in cases {
        let agent = registry
            .agents
            .iter()
            .find(|item| item.id == agent_id)
            .unwrap();
        let selected = selector::select_channel(
            agent,
            &crate::domain::agent_hub::contract::PlatformInstallCapabilities {
                os: os.to_string(),
                architecture: arch.to_string(),
                managers: managers.iter().map(|item| (*item).to_string()).collect(),
                scan_generation: 1,
            },
        )
        .unwrap();
        assert_eq!(
            selected.channel.id, expected,
            "{agent_id} on {os} with {managers:?}"
        );
    }
}

#[test]
fn cursor_npm_and_winget_are_data_but_never_selected() {
    let registry = registry().unwrap();
    let cursor = registry
        .agents
        .iter()
        .find(|agent| agent.id == "cursor")
        .unwrap();
    let npm = cursor
        .channels
        .iter()
        .find(|channel| channel.kind == "npm")
        .unwrap();
    let winget = cursor
        .channels
        .iter()
        .find(|channel| channel.kind == "winget")
        .unwrap();
    assert!(!npm.selectable);
    assert!(!winget.selectable);
    let selected = selector::select_channel(
        cursor,
        &crate::domain::agent_hub::contract::PlatformInstallCapabilities {
            os: "windows".to_string(),
            architecture: "x86_64".to_string(),
            managers: vec!["npm".to_string(), "winget".to_string()],
            scan_generation: 1,
        },
    )
    .unwrap();
    assert_eq!(selected.channel.kind, "official-artifact");
}

#[test]
fn hermes_windows_is_an_unsupported_combination() {
    let registry = registry().unwrap();
    let hermes = registry
        .agents
        .iter()
        .find(|agent| agent.id == "hermes")
        .unwrap();
    let error = selector::select_channel(
        hermes,
        &crate::domain::agent_hub::contract::PlatformInstallCapabilities {
            os: "windows".to_string(),
            architecture: "x86_64".to_string(),
            managers: vec!["npm".to_string()],
            scan_generation: 1,
        },
    )
    .unwrap_err();
    assert!(error.to_string().contains("unsupported_platform"));
}

#[test]
fn contract_surface_keeps_plugin_management_out_of_hub() {
    let surface = contract_surface();
    assert_eq!(surface["pluginManagementBoundary"], "adapter-plugins-only");
    assert_eq!(surface["hostScope"], "desktop");
    assert_eq!(surface["firstBatchIds"], json!(FIRST_BATCH_IDS));
}
