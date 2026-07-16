use super::support::*;
use super::*;

#[test]
fn cli_dispatches_state_targets_and_local_usage() {
    let dir = temp_cli_dir("dispatch");
    {
        let _guard = cli_env_lock().lock().unwrap();
        let _portable = set_portable_dir(&dir);
        let set_state = execute_cli(vec![
            "state".into(),
            "set".into(),
            "targets".into(),
            r#"{"items": []}"#.into(),
        ])
        .unwrap();
        assert_eq!(json_payload(&set_state)["ok"], true);

        let get_state = execute_cli(vec!["state".into(), "get".into(), "targets".into()]).unwrap();
        let got = json_payload(&get_state);
        assert_eq!(got["collection"], "targets");

        let activities = execute_cli(vec![
            "activity".into(),
            "list".into(),
            "--limit".into(),
            "5".into(),
        ])
        .unwrap();
        assert!(json_payload(&activities)["ok"].as_bool().unwrap_or(false));

        let list_targets = execute_cli(vec![
            "targets".into(),
            "scan".into(),
            "--state-root".into(),
            dir.join("client-state").display().to_string(),
        ])
        .unwrap();
        assert_eq!(json_payload(&list_targets)["ok"], true);
        let inspect_target =
            execute_cli(vec!["targets".into(), "inspect".into(), "opencode".into()]).unwrap();
        assert_eq!(
            json_payload(&inspect_target)["target"]["target"],
            "opencode"
        );

        let added = execute_cli(vec![
            "targets".into(),
            "add".into(),
            "--target".into(),
            "opencode".into(),
        ])
        .unwrap();
        assert_eq!(json_payload(&added)["status"], "accepted");

        let native_history_root = dir.join("native-codex-history");
        fs::create_dir_all(&native_history_root).unwrap();
        fs::write(
            native_history_root.join("history.jsonl"),
            [
                r#"{"role":"user","content":"hello from native codex history"}"#,
                r#"{"role":"assistant","content":"native history response"}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let conversations = execute_cli(vec![
            "conversations".into(),
            "list".into(),
            "--agent".into(),
            "codex".into(),
            "--root".into(),
            native_history_root.display().to_string(),
        ])
        .unwrap();
        assert_eq!(
            json_payload(&conversations)["sessions"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(json_payload(&conversations)["mode"], "native-history");

        let usage = execute_cli(vec![
            "agent-usage".into(),
            "scan".into(),
            "--agent".into(),
            "codex".into(),
            "--root".into(),
            native_history_root.display().to_string(),
            "--state-root".into(),
            dir.join("client-state").display().to_string(),
        ])
        .unwrap();
        assert_eq!(json_payload(&usage)["mode"], "local-token-usage");
        assert_eq!(json_payload(&usage)["summary"]["agentCount"], 1);

        let usage_report = execute_cli(vec![
            "agent-usage".into(),
            "report".into(),
            "--agent".into(),
            "codex".into(),
            "--state-root".into(),
            dir.join("client-state").display().to_string(),
        ])
        .unwrap();
        assert_eq!(
            json_payload(&usage_report)["reports"]
                .as_array()
                .unwrap()
                .len(),
            1
        );

        let secret_store: std::sync::Arc<
            dyn lico_client_native::platform::secure_mesh_secret_store::SecureMeshSecretStore,
        > = std::sync::Arc::new(
            lico_client_native::platform::secure_mesh_secret_store::EphemeralSecretStore::new(),
        );
        let relay_config =
            lico_client_native::domain::mobile_relay::with_mobile_relay_secret_store_override(
                secret_store,
                || {
                    execute_cli(vec![
                        "mobile".into(),
                        "relay".into(),
                        "config".into(),
                        "set".into(),
                        "--use-custom-gateway".into(),
                        "true".into(),
                        "--custom-gateway-url".into(),
                        "https://relay.example.test/".into(),
                    ])
                },
            )
            .unwrap();
        assert_eq!(
            json_payload(&relay_config)["config"]["useCustomGateway"],
            true
        );
        assert_eq!(
            json_payload(&relay_config)["config"]["customGatewayUrl"],
            "https://relay.example.test"
        );
    }
}
