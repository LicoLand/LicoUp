use super::{admitted_params, AdmittedCommand, CliExecution};
use anyhow::Result;
use serde_json::{Map, Value};

fn hub_params(command: &AdmittedCommand) -> Value {
    let mut params = admitted_params(
        &[
            ("agentId", command.option_text("agent-id")),
            ("operation", command.option_text("operation")),
            ("confirmation", command.option_text("confirmation")),
        ],
        &[],
        &[("cancel", command.option_flag("cancel"))],
    );
    if let Some(private) = command.option_json("stdin-json") {
        if let (Some(base), Some(extra)) = (params.as_object_mut(), private.as_object()) {
            for (key, value) in extra {
                if key == "agentId" && base.contains_key("agentId") {
                    continue;
                }
                if key == "confirmation" && base.contains_key("confirmation") {
                    continue;
                }
                if key == "operation" && base.contains_key("operation") {
                    continue;
                }
                base.insert(key.clone(), value.clone());
            }
        }
    }
    if params.as_object().is_none() {
        params = Value::Object(Map::new());
    }
    params
}

pub(super) fn handle_catalog(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::domain::agent_hub::catalog(
        &hub_params(&command),
    )?))
}

pub(super) fn handle_plan(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::domain::agent_hub::install_plan(
        &hub_params(&command),
    )?))
}

pub(super) fn handle_apply(command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::domain::agent_hub::install_apply(
        &hub_params(&command),
    )?))
}

#[cfg(test)]
mod tests {
    use super::super::{execute_cli, CliExecution};
    use serde_json::{json, Value};
    use std::env;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-agent-hub-ffi-{}-{}-{}",
            name,
            now.as_secs(),
            now.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn snapshot_params(name: &str) -> Value {
        json!({
            "portableDir": temp_dir(name).to_string_lossy(),
            "platformCapabilities": {
                "os": "macos",
                "architecture": "aarch64",
                "managers": ["homebrew", "npm"],
                "scanGeneration": 4
            },
            "discoveryCandidates": []
        })
    }

    fn json_of(args: Vec<String>) -> Value {
        match execute_cli(args).expect("hub command must execute") {
            CliExecution::Json(value) => value,
            other => panic!("expected json, got {other:?}"),
        }
    }

    #[test]
    fn catalog_projects_eight_cards_from_injected_snapshot() {
        let value = json_of(vec![
            "agent-hub".into(),
            "catalog".into(),
            "--stdin-json".into(),
            snapshot_params("catalog").to_string(),
        ]);
        assert_eq!(value["ok"], true);
        let cards = value["cards"].as_array().expect("cards");
        assert_eq!(cards.len(), 8);
        assert_eq!(cards[0]["id"], "codex");
        assert_eq!(cards[7]["id"], "antigravity");
        assert_eq!(cards[7]["adaptation"], "partial");
        assert_eq!(value["hostScope"], "desktop");
        assert_eq!(cards[0]["homepage"], "https://developers.openai.com/codex");
        assert_eq!(cards[0]["channelKind"], "homebrew");
    }

    #[test]
    fn plan_selects_channel_from_injected_capabilities() {
        let value = json_of(vec![
            "agent-hub".into(),
            "plan".into(),
            "--agent-id".into(),
            "codex".into(),
            "--operation".into(),
            "install".into(),
            "--stdin-json".into(),
            snapshot_params("plan").to_string(),
        ]);
        assert_eq!(value["ok"], true);
        assert_eq!(value["status"], "planned");
        assert_eq!(value["selectedChannel"]["kind"], "homebrew");
        assert!(value["confirmation"]
            .as_str()
            .is_some_and(|token| token.starts_with("agent-hub:")));
    }
}
